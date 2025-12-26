#![no_main]

use alloy_primitives::keccak256;
use alloy_sol_types::SolValue;
use risc0_zkvm::guest::env;
use std::io::Read;
use vote_types::{VotePublicOutput, VoteWitness};

risc0_zkvm::guest::entry!(main);

fn main() {
    let mut input_bytes = Vec::<u8>::new();
    env::stdin().read_to_end(&mut input_bytes).unwrap();

    let VoteWitness { proposalId, votes } = VoteWitness::abi_decode(&input_bytes).unwrap();

    let mut yes: u32 = 0;
    let mut no: u32 = 0;
    let mut digest = keccak256((proposalId).abi_encode());
    for v in votes {
        assert_eq!(v.proposalId, proposalId);
        // TODO: should probably check that voter hasn't already voted and is eligible to vote but lets not worry about that for
        if v.choice {
            yes += 1;
        } else {
            no += 1;
        }

        let vote_commitment = keccak256((v.voter, v.choice, v.proposalId).abi_encode());
        digest = keccak256((digest, vote_commitment).abi_encode());
    }

    let public_output = VotePublicOutput {
        proposalId,
        commitmentsDigest: digest,
        yes,
        no,
    };
    env::commit_slice(public_output.abi_encode().as_slice());
}
