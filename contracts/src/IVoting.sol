pragma solidity ^0.8.20;

interface IVoting {
    function checkProposalTallyState(uint256 proposalId)
        external
        view
        returns (bool tallied, uint32 yesCount, uint32 noCount, bytes32 commitmentsDigest);

    function settleTallyManually(bytes calldata journal, bytes calldata seal) external;

    function createProposal(uint64 proposalDeadline) external returns (uint256 proposalId);

    function resetAllProposals() external;

    function castVote(uint256 proposalId, bytes32 commitment) external;
}
