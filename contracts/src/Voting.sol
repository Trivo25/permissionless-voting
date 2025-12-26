pragma solidity ^0.8.20;

import {IRiscZeroVerifier, Receipt, ReceiptClaim, ReceiptClaimLib} from "risc0/IRiscZeroVerifier.sol";
import {IERC1271} from "openzeppelin/contracts/interfaces/IERC1271.sol";
import {ProofRequest} from "boundless/types/ProofRequest.sol";
import {PredicateType} from "boundless/types/Predicate.sol";
import {RequestId, RequestIdLibrary} from "boundless/types/RequestId.sol";
import {IBoundlessMarketCallback} from "boundless/IBoundlessMarketCallback.sol";
import {ImageID} from "./ImageID.sol";
import {IBoundlessMarket} from "boundless/IBoundlessMarket.sol";


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
    uint32 proposalId;
    bytes32 commitmentsDigest;
    uint32 yes;
    uint32 no;
}

contract Voting is IBoundlessMarketCallback, IERC1271 {
    // boundless and risc0 specifics
    using ReceiptClaimLib for ReceiptClaim;
    using RequestIdLibrary for RequestId;

    IRiscZeroVerifier public immutable VERIFIER;
    bytes32 public constant IMAGE_ID = ImageID.VOTING_TALLY_ID;
    IBoundlessMarket public immutable BOUNDLESS_MARKET;
    bytes32 private immutable MARKET_DOMAIN_SEPARATOR;

    bytes4 internal constant ERC1271_MAGICVALUE = 0x1626ba7e;
    uint96 internal constant MIN_CALLBACK_GAS_LIMIT = 100000;

    // tracking all proposals
    uint32 public proposalCount;

    // mapping of proposalID to proposal
    mapping(uint32 => Proposal) public proposals;

    event Proof(VotePublicOutput publicOutput);

     
    constructor(IRiscZeroVerifier _verifier, IBoundlessMarket boundlessMarket) {
        VERIFIER = _verifier;
        BOUNDLESS_MARKET = boundlessMarket;
        MARKET_DOMAIN_SEPARATOR = boundlessMarket.eip712DomainSeparator();
        proposalCount = 0;
    }

    receive() external payable {}

    function depositToBoundlessMarket() external payable {
        require(msg.value > 0, "no value");
        BOUNDLESS_MARKET.deposit{value: msg.value}();
    }

    function createProposal(
        uint64 proposalDeadline
    ) external returns (uint32 proposalId) {
        require(proposalCount < type(uint32).max, "proposal limit reached");
        require(
            proposalDeadline > block.timestamp,
            "cannot create proposals with deadlines in the past"
        );
        proposalId = proposalCount++;
        proposals[proposalId] = Proposal({
            creator: msg.sender,
            proposalId: proposalId,
            commitDeadline: proposalDeadline,
            commitmentsDigest: keccak256(abi.encode(proposalId)),
            tallied: false,
            yesCount: 0,
            noCount: 0,
            votesCount: 0
        });

        return proposalId;
    }

    function castVote(uint32 proposalId, bytes32 voterCommitment) external {
        Proposal storage p = proposals[proposalId];

        require(p.creator != address(0), "proposal does not exist");
        require(block.timestamp < p.commitDeadline, "commit phase over");
        // TODO: verify that voter has not voted before and is eligible to vote (omitted for simplicity)
        // update accumulator, digest = H(prevDigest || voterCommitment)
        p.commitmentsDigest = keccak256(
            abi.encode(p.commitmentsDigest, voterCommitment)
        );
        p.votesCount += 1;
        proposals[proposalId] = p;
    }


    // this is no longer needed but keeping it in here for reference
    function settleTallyManually(
        bytes calldata journal,
        bytes calldata seal
    ) external {
        // in case the proposer wants to settle the tally manually via a manual trigger to boundless

        VotePublicOutput memory publicOutput = abi.decode(
            journal,
            (VotePublicOutput)
        );

        require(
            publicOutput.commitmentsDigest ==
                proposals[publicOutput.proposalId].commitmentsDigest,
            "commitments digest mismatch"
        );

        VERIFIER.verify(seal, IMAGE_ID, sha256(journal));

        // TODO: lots of checks needed here. eg that tally has not been settled yet, that the proposal exists, the deadline has passed, etc.

        Proposal storage p = proposals[publicOutput.proposalId];
        p.yesCount = publicOutput.yes;
        p.noCount = publicOutput.no;
        p.tallied = true;
    }

    function checkProposalTallyState(
        uint32 proposalId
    )
        external
        view
        returns (
            bool tallied,
            uint32 yesCount,
            uint32 noCount,
            bytes32 commitmentsDigest
        )
    {
        Proposal storage p = proposals[proposalId];
        return (p.tallied, p.yesCount, p.noCount, p.commitmentsDigest);
    }

    function handleProof(
        bytes32 imageId,
        bytes calldata journal,
        bytes calldata seal
    ) public {
        require(msg.sender == address(BOUNDLESS_MARKET), "Invalid sender");
        require(imageId == IMAGE_ID, "Invalid Image ID");

        VotePublicOutput memory publicOutput = abi.decode(
            journal,
            (VotePublicOutput)
        );

        require(
            publicOutput.commitmentsDigest ==
                proposals[publicOutput.proposalId].commitmentsDigest,
            "commitments digest mismatch"
        );
        VERIFIER.verify(seal, IMAGE_ID, sha256(journal));

        // TODO: lots of checks needed here. eg that tally has not been settled yet, that the proposal exists, the deadline has passed, etc.

        Proposal storage p = proposals[publicOutput.proposalId];
        p.yesCount = publicOutput.yes;
        p.noCount = publicOutput.no;
        p.tallied = true;

        emit Proof(publicOutput);
    }

    function isValidSignature(
        bytes32 hash,
        bytes memory signature
    ) external view override returns (bytes4 magicValue) {
        if (_isAuthorizedRequest(hash, signature)) {
            return ERC1271_MAGICVALUE;
        }
        return 0xffffffff;
    }


    function _isAuthorizedRequest(bytes32 requestHash, bytes memory signature) internal view returns (bool) {
        (ProofRequest memory request, VotePublicOutput memory expectedOutput) =
            abi.decode(signature, (ProofRequest, VotePublicOutput));

        if (_hashTypedData(request.eip712Digest()) != requestHash) {
            return false;
        }

        if (!request.id.isSmartContractSigned()) {
            return false;
        }

        (address client, uint32 proposalIndex) = request.id.clientAndIndex();
        if (client != address(this) || proposalIndex != uint32(expectedOutput.proposalId)) {
            return false;
        }

        Proposal storage proposal = proposals[expectedOutput.proposalId];
        if (proposal.creator == address(0) || proposal.tallied) {
            return false;
        }
        if (proposal.commitmentsDigest != expectedOutput.commitmentsDigest) {
            return false;
        }

        if (request.requirements.callback.addr != address(this)) {
            return false;
        }
        if (request.requirements.callback.gasLimit < MIN_CALLBACK_GAS_LIMIT) {
            return false;
        }
        if (request.requirements.predicate.predicateType != PredicateType.DigestMatch) {
            return false;
        }
        if (request.requirements.predicate.data.length != 64) {
            return false;
        }

        bytes32 predicateImageId;
        bytes32 predicateJournalDigest;
        bytes memory predicateData = request.requirements.predicate.data;
        assembly {
            predicateImageId := mload(add(predicateData, 32))
            predicateJournalDigest := mload(add(predicateData, 64))
        }

        if (predicateImageId != IMAGE_ID) {
            return false;
        }
        if (predicateJournalDigest != sha256(abi.encode(expectedOutput))) {
            return false;
        }

        return true;
    }

    function _hashTypedData(bytes32 dataHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", MARKET_DOMAIN_SEPARATOR, dataHash));
    }
}
