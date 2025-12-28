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
    bool tallied; // state of whether tally has been completed
    uint32 yesCount; 
    uint32 noCount;
    uint32 votesCount;
}

// aka what's called the journal i
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

    // lifecycle events
    event ProposalCreated(uint32 indexed proposalId, address indexed creator, uint64 commitDeadline);
    event VoteCommitted(uint32 indexed proposalId, address indexed voter, bytes32 commitment);
    event TallyCompleted(VotePublicOutput publicOutput);

     
    constructor(IRiscZeroVerifier _verifier, IBoundlessMarket boundlessMarket) {
        VERIFIER = _verifier;
        BOUNDLESS_MARKET = boundlessMarket;
        MARKET_DOMAIN_SEPARATOR = boundlessMarket.eip712DomainSeparator();
        proposalCount = 0;
    }

    receive() external payable {}

    // needed for the smart contract requestor to fund requests, must be called first
    function depositToBoundlessMarket() external payable {
        require(msg.value > 0, "no value");
        BOUNDLESS_MARKET.deposit{value: msg.value}();
    }

    // create a new proposal on the smart contract
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

        emit ProposalCreated(proposalId, msg.sender, proposalDeadline);
        return proposalId;
    }

    // cast a vote by submitting a commitment of the vote to the proposal
    function castVote(uint32 proposalId, bytes32 voterCommitment) external {
        Proposal storage p = proposals[proposalId];

        require(block.timestamp < p.commitDeadline, "commit phase over");
        // TODO: verify that voter has not voted before and is eligible to vote (omitted for simplicity)

        // update accumulator, digest = H(prevDigest || voterCommitment)
        // where voterCommitment = H(voterAddress, choice, proposalId)
        // which is calculated off-chain 
        p.commitmentsDigest = keccak256(
            abi.encode(p.commitmentsDigest, voterCommitment)
        );
        p.votesCount += 1;
        proposals[proposalId] = p;

        emit VoteCommitted(proposalId, msg.sender, voterCommitment);
    }


    // this is no longer needed but keeping it in here for reference
    // settles a tally manually by providing the proof journal and seal
    // not as callback from boundless
    function settleTallyManually(
        bytes calldata journal,
        bytes calldata seal
    ) external {
        VotePublicOutput memory publicOutput = abi.decode(
            journal,
            (VotePublicOutput)
        );

        Proposal storage p = proposals[publicOutput.proposalId];

        require(!p.tallied, "already tallied");
        require(publicOutput.commitmentsDigest == p.commitmentsDigest, "commitments digest mismatch");

        // looks up the verification of the proof
        VERIFIER.verify(seal, IMAGE_ID, sha256(journal));

        p.yesCount = publicOutput.yes;
        p.noCount = publicOutput.no;
        p.tallied = true;

        emit TallyCompleted(publicOutput);
    }

    // fetches some state about the proposal tally
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

    // called by boundless market when proof is ready
    // triggered verificaiton of the tally proof and updates the ally accordingly
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

        Proposal storage p = proposals[publicOutput.proposalId];
        require(!p.tallied, "already tallied");
        require(publicOutput.commitmentsDigest == p.commitmentsDigest, "commitments digest mismatch");

        // commented out to allow quicker testing
        //require(block.timestamp >= p.commitDeadline, "commit phase not over");

        VERIFIER.verify(seal, IMAGE_ID, sha256(journal));

        p.yesCount = publicOutput.yes;
        p.noCount = publicOutput.no;
        p.tallied = true;

        emit TallyCompleted(publicOutput);
    }


    // authorization for boundless market when fulfilling proof requests
    // allows permissionless proof requests/tallies by users 
    function isValidSignature(bytes32 hash, bytes memory signature)
        external
        view
        override
        returns (bytes4)
    {
        ProofRequest memory request = abi.decode(signature, (ProofRequest));

        (address client, uint32 proposalId, bool smartContractSigned) = request.id.clientIndexAndSignatureType();
        if (client != address(this) || !smartContractSigned) {
            return 0xffffffff;
        } 

        Proposal storage proposal = proposals[proposalId];


        if (proposal.creator == address(0) || proposal.tallied) {
            return 0xffffffff;
        }

        if (request.requirements.callback.addr != address(this)) {
            return 0xffffffff;
        }
        if (request.requirements.callback.gasLimit < MIN_CALLBACK_GAS_LIMIT) {
            return 0xffffffff;
        } 

        if (_hashTypedData(request.eip712Digest()) != hash) {
            return 0xffffffff;
        }

        return ERC1271_MAGICVALUE;
    }

    function _hashTypedData(bytes32 dataHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", MARKET_DOMAIN_SEPARATOR, dataHash));
    }
}
