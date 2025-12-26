use alloy_primitives::{keccak256, Address, U256};
use alloy_sol_types::SolValue;
use guests::VOTING_TALLY_ELF;
use risc0_zkvm::{default_executor, ExecutorEnv};
use vote_types::{Vote, VotePublicOutput, VoteWitness};

#[test]
fn tally_votes_basic() {
    let proposal_id = U256::from(0);
    // manual dummy inputs
    let input = VoteWitness {
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

    let env = ExecutorEnv::builder()
        .write_slice(&input.abi_encode())
        .build()
        .unwrap();

    let session_info = default_executor().execute(env, VOTING_TALLY_ELF).unwrap();

    let out = VotePublicOutput::abi_decode(&session_info.journal.bytes).unwrap();
    assert_eq!(out.proposalId, proposal_id);
    assert_eq!(out.yes, 2);
    assert_eq!(out.no, 1);

    let mut expected_digest = keccak256((proposal_id).abi_encode());
    println!(
        "Expected digest calculation starts with: {:?}",
        expected_digest
    );

    for vote in &input.votes {
        let vote_commitment = keccak256((vote.voter, vote.choice, vote.proposalId).abi_encode());
        expected_digest = keccak256((expected_digest, vote_commitment).abi_encode());
    }
    assert_eq!(out.commitmentsDigest, expected_digest);
}
