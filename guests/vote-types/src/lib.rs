use alloy_sol_types::sol;

sol! {
     #[derive(Debug)]
    struct Vote {
        uint256 proposalId;
        address voter;
        bool choice;
    }

    #[derive(Debug)]
    struct VoteWitness {
        uint256 proposalId;
        Vote[] votes;
    }

    #[derive(Debug)]
    struct VotePublicOutput {
        uint256 proposalId;
        bytes32 commitmentsDigest;
        uint32 yes;
        uint32 no;
    }
}
