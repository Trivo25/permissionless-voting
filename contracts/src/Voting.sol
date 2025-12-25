pragma solidity ^0.8.20;

import {IRiscZeroVerifier} from "risc0/IRiscZeroVerifier.sol";
import {ImageID} from "./ImageID.sol";

struct Proposal {
    address creator;
    uint32 proposalId;
    uint64 commitDeadline; // timestamp
    bytes32 commitmentsDigest; // accumulator over (voter, commitment) in commit order
    bool tallied;
    uint32 yesCount;
    uint32 noCount;
    uint32 votesCount;
}

struct VotePublicOutput {
    uint256 proposalId;
    bytes32 commitmentsDigest;
    uint32 yes;
    uint32 no;
}

contract Voting {
    IRiscZeroVerifier public immutable VERIFIER;
    bytes32 public constant IMAGE_ID = ImageID.VOTING_TALLY_ID;
    // tracking all proposals
    uint256 public proposalCount;

    // mapping of proposalID to proposal
    mapping(uint256 => Proposal) public proposals;

    constructor(IRiscZeroVerifier _verifier) {
        VERIFIER = _verifier;
        proposalCount = 0;
    }

    function createProposal(uint64 proposalDeadline) external returns (uint256 proposalId) {
        require(proposalDeadline > block.timestamp, "cannot create proposals with deadlines in the past");
        proposalId = proposalCount++;
        proposals[proposalId] = Proposal({
            creator: msg.sender,
            proposalId: uint32(proposalId),
            commitDeadline: proposalDeadline,
            commitmentsDigest: keccak256(abi.encode(proposalId)),
            tallied: false,
            yesCount: 0,
            noCount: 0,
            votesCount: 0
        });

        return proposalId;
    }

    function castVote(uint256 proposalId, bytes32 voterCommitment) external {
        Proposal storage p = proposals[proposalId];

        require(p.creator != address(0), "proposal does not exist");
        require(block.timestamp < p.commitDeadline, "commit phase over");
        // TODO: verify that voter has not voted before and is eligible to vote (omitted for simplicity)
        // update accumulator, digest = H(prevDigest || voterCommitment)
        p.commitmentsDigest = keccak256(abi.encode(p.commitmentsDigest, voterCommitment));
        p.votesCount += 1;
        proposals[proposalId] = p;
    }

    function requestTally(uint256 proposalId) external {}

    function settleTallyManually(bytes calldata journal, bytes calldata seal) external {
        // in case the proposer wants to settle the tally manually via a manual trigger to boundless

        VotePublicOutput memory publicOutput = abi.decode(journal, (VotePublicOutput));

        require(
            publicOutput.commitmentsDigest == proposals[publicOutput.proposalId].commitmentsDigest,
            "commitments digest mismatch"
        );

        VERIFIER.verify(seal, IMAGE_ID, sha256(journal));

        /* 
        // skipping a time check for testing purposes
        require(
            block.timestamp > proposals[publicOutput.proposalId].commitDeadline, "cannot tally before commit deadline"
        );
        */

        Proposal storage p = proposals[publicOutput.proposalId];
        p.yesCount = publicOutput.yes;
        p.noCount = publicOutput.no;
        p.tallied = true;
    }

    function checkProposalTallyState(uint256 proposalId)
        external
        view
        returns (bool tallied, uint32 yesCount, uint32 noCount, bytes32 commitmentsDigest)
    {
        Proposal storage p = proposals[proposalId];
        return (p.tallied, p.yesCount, p.noCount, p.commitmentsDigest);
    }

    // hacky way for testing live environments
    function resetAllProposals() external {
        for (uint256 i = 0; i < proposalCount; i++) {
            delete proposals[i];
        }
        proposalCount = 0;
    }
}
