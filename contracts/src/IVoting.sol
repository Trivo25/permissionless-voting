pragma solidity ^0.8.20;

interface IVoting {
    function checkProposalTallyState(uint32 proposalId)
        external
        view
        returns (bool tallied, uint32 yesCount, uint32 noCount, bytes32 commitmentsDigest);

    function settleTallyManually(bytes calldata journal, bytes calldata seal) external;

    function createProposal(uint64 proposalDeadline) external returns (uint32 proposalId);

    function castVote(uint32 proposalId, bytes32 commitment) external;

    // explicitly redeclare so bindings include it
    function handleProof(bytes32 imageId, bytes calldata journal, bytes calldata seal) external;
}
