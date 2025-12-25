pragma solidity ^0.8.20;

import {IRiscZeroVerifier} from "risc0/IRiscZeroVerifier.sol";

import {ImageID} from "./ImageID.sol"; // auto-generated contract after running `cargo build`.

interface IVoting {}

struct Proposal {
    address creator;
    uint32 proposalId;
    uint64 commitDeadline; // timestamp
    bytes32 commitmentsDigest; // accumulator over (voter, commitment) in commit order
    bool tallied;
    uint32 yesCount;
    uint32 noCount;
}

contract Voting is IVoting {
    // template specifics

    // verifier contract address

    IRiscZeroVerifier public immutable VERIFIER;

    // image_id of the risc0 zkvm program, similar to a verification key of the circuit

    bytes32 public constant IMAGE_ID = ImageID.IS_EVEN_ID;

    // tracking all proposals

    uint256 public proposalCount;

    // mapping of proposalID to proposal

    mapping(uint256 => Proposal) public proposals;

    constructor(IRiscZeroVerifier _verifier) {
        VERIFIER = _verifier;

        number = 0;
    }

    function createProposal(uint64 proposalDeadline) external returns (uint256 proposalId) {}

    function commitVote(uint256 proposalId, bytes32 commitment) external {}

    function requestTally(uint256 proposalId) external {}
}
