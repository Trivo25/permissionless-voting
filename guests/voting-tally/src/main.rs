use alloy_sol_types::{sol, SolValue};
use risc0_zkvm::guest::env;
use std::io::Read;

risc0_zkvm::guest::entry!(main);

sol! {
    struct VoteWitness {
        uint256 proposalId;
        bool[] votes;
    }

    struct VotePublicOutput {
        uint256 proposalId;
        uint32 yes;
        uint32 no;
    }
}

fn main() {
    let mut input_bytes = Vec::<u8>::new();
    env::stdin().read_to_end(&mut input_bytes).unwrap();

    let input = VoteWitness::abi_decode(&input_bytes).unwrap();

    let mut yes: u32 = 0;
    let mut no: u32 = 0;
    for v in input.votes {
        if v {
            yes += 1;
        } else {
            no += 1;
        }
    }

    let publicOutput = VotePublicOutput {
        proposalId: input.proposalId,
        yes,
        no,
    };
    let journal_bytes = publicOutput.abi_encode();
    env::commit_slice(&journal_bytes);
}
