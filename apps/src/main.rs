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
    primitives::{keccak256, Address, Bytes, U256, U64},
    signers::local::PrivateKeySigner,
    sol_types::SolValue,
};
use anyhow::{bail, Context, Result};
use boundless_market::{
    request_builder::RequirementParams, Client, Deployment, StorageProviderConfig,
};
use clap::Parser;
use guests::vote_types::{Vote, VotePublicOutput, VoteWitness};
use guests::VOTING_TALLY_ELF;
use tokio::join;
use url::Url;
use voting_contract::IVoting::IVotingInstance;
/// Timeout for the transaction to be confirmed.
pub const TX_TIMEOUT: Duration = Duration::from_secs(30);

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

    let client = Client::builder()
        .with_rpc_url(args.rpc_url)
        .with_deployment(args.deployment)
        .with_storage_provider_config(&args.storage_config)?
        .with_private_key(args.private_key)
        .build()
        .await
        .context("failed to build boundless client")?;

    let voting_contract = IVoting::new(args.voting_contract_address, client.provider().clone());

    // reset proposals on contract and create a new one
    tracing::info!("Resetting all proposals on the voting contract");
    reset_all_proposals(&client, &voting_contract).await?;
    tracing::info!("Creating new proposal");

    create_new_proposal(&client, &voting_contract).await?;

    // manual dummy inputs
    let votes = VoteWitness {
        proposalId: U256::from(0),
        votes: vec![
            Vote {
                proposalId: U256::from(0),
                voter: Address::from([0x01u8; 20]),
                choice: true,
            },
            Vote {
                proposalId: U256::from(0),
                voter: Address::from([0x02u8; 20]),
                choice: false,
            },
            Vote {
                proposalId: U256::from(0),
                voter: Address::from([0x03u8; 20]),
                choice: true,
            },
        ],
    };
    let proposal_meta_data = get_proposal_meta_data(&voting_contract, votes.proposalId).await?;
    tracing::info!(
        "Current commitments digest on contract: {:?}",
        proposal_meta_data.commitmentsDigest
    );
    tracing::info!("Casting votes");

    cast_vote(&client, &voting_contract, &votes.votes[0]).await?;
    cast_vote(&client, &voting_contract, &votes.votes[1]).await?;
    cast_vote(&client, &voting_contract, &votes.votes[2]).await?;

    tracing::info!("Casted all votes, submitting tally request");

    let proposal_meta_data = get_proposal_meta_data(&voting_contract, votes.proposalId).await?;
    tracing::info!(
        "Current commitments digest on contract: {:?}",
        proposal_meta_data.commitmentsDigest
    );
    let request = if let Some(program_url) = args.program_url {
        client
            .new_request()
            .with_program_url(program_url)?
            .with_stdin(votes.abi_encode().clone())
    } else {
        client
            .new_request()
            .with_program(VOTING_TALLY_ELF)
            .with_stdin(votes.abi_encode().clone())
    };

    let (request_id, expires_at) = client.submit_onchain(request).await?;

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
    let journal_bytes = fulfillment_data.journal().unwrap();

    let journal = VotePublicOutput::abi_decode(journal_bytes)
        .context("failed to decode journal from fulfillment data")?;

    tracing::info!("Vote tally results for proposal {:?}", journal);

    // get current commitment for proposal from contract
    let proposal_meta_data = get_proposal_meta_data(&voting_contract, votes.proposalId).await?;
    tracing::info!(
        "Current commitments digest on contract: {:?}",
        proposal_meta_data.commitmentsDigest
    );
    settle_tally(&client, &voting_contract, &journal_bytes, &fulfillment.seal).await?;

    // query state of contract and proposal to check if the tally was completed
    let proposal_meta_data = get_proposal_meta_data(&voting_contract, votes.proposalId).await?;

    tracing::info!(
        "Proposal {:?} tallied: {:?}. with yes votes: {:?}, no votes: {:?}",
        votes.proposalId,
        proposal_meta_data.tallied,
        proposal_meta_data.yesCount,
        proposal_meta_data.noCount
    );

    Ok(())
}

async fn reset_all_proposals(
    client: &Client,
    voting_contract: &IVotingInstance<alloy::providers::DynProvider>,
) -> Result<()> {
    let reset_proposals_call = voting_contract.resetAllProposals().from(client.caller());
    let pending_tx = reset_proposals_call
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
    return Ok(());
}

async fn create_new_proposal(
    client: &Client,
    voting_contract: &IVotingInstance<alloy::providers::DynProvider>,
) -> Result<()> {
    let deadline_timestamp = (std::time::SystemTime::now()
        + std::time::Duration::from_secs(60 * 60 * 1)) // 1 hour from now
    .duration_since(std::time::UNIX_EPOCH)
    .unwrap()
    .as_secs();
    let create_proposal_call = voting_contract
        .createProposal(deadline_timestamp)
        .from(client.caller());
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
    return Ok(());
}

async fn settle_tally(
    client: &Client,
    voting_contract: &IVotingInstance<alloy::providers::DynProvider>,
    journal_bytes: &Bytes,
    seal: &Bytes,
) -> Result<()> {
    let call_settle_tally_manually = voting_contract
        .settleTallyManually(journal_bytes.clone(), seal.clone())
        .from(client.caller());

    tracing::info!("Calling settleTallyManually function");
    let pending_tx = call_settle_tally_manually
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
    return Ok(());
}

async fn cast_vote(
    client: &Client,
    voting_contract: &IVotingInstance<alloy::providers::DynProvider>,
    vote: &Vote,
) -> Result<()> {
    let commitment = keccak256((vote.voter.clone(), vote.choice, vote.proposalId).abi_encode());
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
    return Ok(());
}

async fn get_proposal_meta_data(
    voting_contract: &IVotingInstance<alloy::providers::DynProvider>,
    proposal_id: U256,
) -> Result<IVoting::checkProposalTallyStateReturn> {
    let proposal_meta_data = voting_contract
        .checkProposalTallyState(U256::from(proposal_id))
        .call()
        .await
        .context("failed to get proposal tally state from contract")?;
    Ok(proposal_meta_data)
}
