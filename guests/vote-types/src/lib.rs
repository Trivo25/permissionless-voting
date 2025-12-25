use alloy_sol_types::sol;

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
