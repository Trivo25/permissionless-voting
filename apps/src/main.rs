// Copyright 2024 RISC Zero, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

use std::time::Duration;

use crate::voting_contract::IVoting;
use alloy::{
    primitives::{keccak256, utils::parse_ether, Address, Bytes, B256, U256},
    signers::local::PrivateKeySigner,
    sol_types::SolValue,
};
use anyhow::{anyhow, bail, Context, Result};
use boundless_market::{
    contracts::{Fulfillment, RequestId},
    request_builder::{OfferParams, RequirementParams},
    Client, Deployment, StorageProviderConfig,
};
use clap::Parser;
use guests::vote_types::{Vote, VotePublicOutput, VoteWitness};
use guests::VOTING_TALLY_ELF;
use url::Url;
use voting_contract::IVoting::IVotingInstance;

/// Timeout for the transaction to be confirmed.
pub const TX_TIMEOUT: Duration = Duration::from_secs(45);

mod voting_contract {
    alloy::sol!(
        #![sol(rpc, all_derives)]
        "../contracts/src/IVoting.sol"
    );
}

/// Arguments of the publisher CLI.
#[derive(Parser, Debug)]
#[clap(author, version, about, long_about = None)]
struct Args {
    /// URL of the Ethereum RPC endpoint.
    #[clap(short, long, env)]
    rpc_url: Url,
    /// Private key used to interact with the EvenNumber contract and the Boundless Market.
    #[clap(long, env)]
    private_key: PrivateKeySigner,
    /// Address of the EvenNumber contract.
    #[clap(short, long, env)]
    voting_contract_address: Address,
    /// URL where provers can download the program to be proven.
    #[clap(long, env)]
    program_url: Option<Url>,
    /// Submit the request offchain via the provided order stream service url.
    #[clap(short, long, requires = "order_stream_url")]
    offchain: bool,
    /// Configuration for the StorageProvider to use for uploading programs and inputs.
    #[clap(flatten, next_help_heading = "Storage Provider")]
    storage_config: StorageProviderConfig,
    /// Deployment of the Boundless contracts and services to use.
    ///
    /// Will be automatically resolved from the connected chain ID if unspecified.
    #[clap(flatten, next_help_heading = "Boundless Market Deployment")]
    deployment: Option<Deployment>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    match dotenvy::dotenv() {
        Ok(path) => tracing::debug!("Loaded environment variables from {:?}", path),
        Err(e) if e.not_found() => tracing::debug!("No .env file found"),
        Err(e) => bail!("failed to load .env file: {}", e),
    }
    let args = Args::parse();
    let program_url = args.program_url.clone();

    let client = Client::builder()
        .with_rpc_url(args.rpc_url)
        .with_deployment(args.deployment)
        .with_storage_provider_config(&args.storage_config)?
        .with_private_key(args.private_key)
        .build()
        .await
        .context("failed to build boundless client")?;

    // instance of the voting contract
    let voting_contract = IVoting::new(args.voting_contract_address, client.provider().clone());

    // create new proposal
    let proposal_id = create_new_proposal(&client, &voting_contract).await?;

    // prepare and cast votes
    let casted_votes = prepare_and_cast_votes(&client, &voting_contract, proposal_id).await?;

    // build request id using the proposal_id as nonce/index
    let request_id =
        RequestId::new(args.voting_contract_address, proposal_id).set_smart_contract_signed_flag();

    // prepares the proof request using the list of all casted votes as input to the prover
    let stdin = casted_votes.abi_encode().clone();

    // specifies the callback address for boundless to call once request has been fulfilled
    let requirements = build_requirement_params(args.voting_contract_address)?;
    // specifies the offer parameters for the proof request, not needed but was playing around with it
    let offer_params = build_offer_params()?;

    let base_request = if let Some(url) = program_url {
        tracing::info!("Using program URL: {}", url);
        client
            .new_request()
            .with_request_id(request_id)
            .with_program_url(url)?
            .with_stdin(stdin)
            .with_requirements(requirements)
            .with_offer(offer_params)
    } else {
        tracing::info!("Using built-in ELF for voting tally");
        client
            .new_request()
            .with_request_id(request_id)
            .with_program(VOTING_TALLY_ELF)
            .with_stdin(stdin)
            .with_requirements(requirements)
            .with_offer(offer_params)
    };

    let proof_request = client
        .build_request(base_request)
        .await
        .context("failed to build proof request")?;

    // calculates the signature for smart contract authorization
    let signature: Bytes = proof_request.clone().abi_encode().into();
    let (submitted_request_id, expires_at) = client
        .submit_request_onchain_with_signature(&proof_request, signature)
        .await?;

    // requests the actual proof via boundless
    request_boundless_proof(&client, submitted_request_id, expires_at)
        .await
        .context("failed to get proof fulfilment from Boundless Market")?;

    // query state of contract and proposal to check if the tally was completed
    let proposal_meta_data = get_proposal_meta_data(&voting_contract, proposal_id).await?;

    tracing::info!(
        "Proposal {:?} tallied: {:?}. with yes votes: {:?}, no votes: {:?}",
        proposal_id,
        proposal_meta_data.tallied,
        proposal_meta_data.yesCount,
        proposal_meta_data.noCount
    );

    if !proposal_meta_data.tallied {
        bail!("proposal tally was not completed onchain");
    }

    Ok(())
}

async fn create_new_proposal(
    client: &Client,
    voting_contract: &IVotingInstance<alloy::providers::DynProvider>,
) -> Result<u32> {
    tracing::info!("Creating new proposal");
    let deadline_timestamp = (std::time::SystemTime::now()
        + std::time::Duration::from_secs(60 * 60 * 1)) // 1 hour from now
    .duration_since(std::time::UNIX_EPOCH)
    .unwrap()
    .as_secs();

    let create_proposal_call = voting_contract
        .createProposal(deadline_timestamp)
        .from(client.caller());

    let proposal_id = create_proposal_call
        .call()
        .await
        .context("failed to retrieve proposal ID")?;
    let pending_tx = create_proposal_call
        .send()
        .await
        .context("failed to broadcast tx")?;

    tracing::info!("Broadcasting tx {}", pending_tx.tx_hash());
    let tx_hash = pending_tx
        .with_timeout(Some(TX_TIMEOUT))
        .watch()
        .await
        .context("failed to confirm tx")?;

    tracing::info!("Tx {:?} confirmed", tx_hash);
    tracing::info!("New proposal created with ID {:?}", proposal_id);
    Ok(proposal_id)
}

async fn cast_vote(
    client: &Client,
    voting_contract: &IVotingInstance<alloy::providers::DynProvider>,
    vote: &Vote,
) -> Result<()> {
    let commitment = keccak256((vote.voter, vote.choice, vote.proposalId).abi_encode());
    let call_cast_vote = voting_contract
        .castVote(vote.proposalId, commitment)
        .from(client.caller());

    tracing::info!("Calling castVote function");
    let pending_tx = call_cast_vote
        .send()
        .await
        .context("failed to broadcast tx")?;
    tracing::info!("Broadcasting tx {}", pending_tx.tx_hash());
    let tx_hash = pending_tx
        .with_timeout(Some(TX_TIMEOUT))
        .watch()
        .await
        .context("failed to confirm tx")?;
    tracing::info!("Tx {:?} confirmed", tx_hash);
    Ok(())
}

async fn get_proposal_meta_data(
    voting_contract: &IVotingInstance<alloy::providers::DynProvider>,
    proposal_id: u32,
) -> Result<IVoting::checkProposalTallyStateReturn> {
    let proposal_meta_data = voting_contract
        .checkProposalTallyState(proposal_id)
        .call()
        .await
        .context("failed to get proposal tally state from contract")?;
    Ok(proposal_meta_data)
}

async fn prepare_and_cast_votes(
    client: &Client,
    voting_contract: &IVotingInstance<alloy::providers::DynProvider>,
    proposal_id: u32,
) -> Result<VoteWitness> {
    // manual dummy inputs
    let votes = VoteWitness {
        proposalId: proposal_id,
        votes: vec![
            Vote {
                proposalId: proposal_id,
                voter: Address::from([0x01u8; 20]),
                choice: true,
            },
            Vote {
                proposalId: proposal_id,
                voter: Address::from([0x02u8; 20]),
                choice: false,
            },
            Vote {
                proposalId: proposal_id,
                voter: Address::from([0x03u8; 20]),
                choice: true,
            },
        ],
    };

    tracing::info!("Casting {} votes", votes.votes.len());
    for vote in &votes.votes {
        cast_vote(client, voting_contract, vote).await?;
    }
    tracing::info!("All votes committed");

    Ok(votes)
}

async fn request_boundless_proof(
    client: &Client,
    request_id: U256,
    expires_at: u64,
) -> Result<(Bytes, Fulfillment)> {
    tracing::info!("Waiting for request {:x} to be fulfilled", request_id);
    let fulfillment = client
        .wait_for_request_fulfillment(
            request_id,
            Duration::from_secs(5), // check every 5 seconds
            expires_at,
        )
        .await?;
    tracing::info!("Request {:x} fulfilled", request_id);

    let fulfillment_data = fulfillment.data()?;
    let journal_bytes = fulfillment_data
        .journal()
        .context("fulfillment response missing journal bytes")?;

    let journal = VotePublicOutput::abi_decode(journal_bytes)
        .context("failed to decode journal from fulfillment data")?;

    tracing::info!("Received proof with journal {:?}", journal);

    Ok((journal_bytes.clone(), fulfillment))
}

fn build_offer_params() -> Result<OfferParams> {
    Ok(OfferParams::builder()
        .ramp_up_period(200)
        .max_price(parse_ether("0.01")?)
        .lock_collateral(U256::from(5u64) * U256::from(1_000_000_000_000_000_000u64))
        .build()
        .expect("offer params"))
}

fn build_requirement_params(callback_address: Address) -> Result<RequirementParams> {
    Ok(RequirementParams::builder()
        .callback_address(callback_address)
        .callback_gas_limit(100_000)
        .build()
        .expect("requirements"))
}
