pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Voting} from "../src/Voting.sol";

contract VotingTester is Test {
    Voting public voting;

    function setUp() public {
        voting = new Voting();
        assertEq(voting.proposalCount(), 0);
    }
}
