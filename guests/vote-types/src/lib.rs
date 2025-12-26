use alloy_sol_types::sol;

sol! {
     #[derive(Debug)]
    struct Vote {
        uint32 proposalId;
        address voter;
        bool choice;
    }

    #[derive(Debug)]
    struct VoteWitness {
        uint32 proposalId;
        Vote[] votes;
    }

    #[derive(Debug)]
    struct VotePublicOutput {
        uint32 proposalId;
        bytes32 commitmentsDigest;
        uint32 yes;
        uint32 no;
    }
}
