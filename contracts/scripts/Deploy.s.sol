pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IRiscZeroVerifier} from "risc0/IRiscZeroVerifier.sol";
import {Voting} from "../src/Voting.sol";

contract Deploy is Script {
    function run() external {
        // load ENV variables first
        uint256 key = vm.envUint("PRIVATE_KEY");
        address verifierAddress = vm.envAddress("VERIFIER_ADDRESS");
        vm.startBroadcast(key);

        IRiscZeroVerifier verifier = IRiscZeroVerifier(verifierAddress);
        Voting voting = new Voting(verifier);
        address votingAddress = address(voting);
        console2.log("Deployed Voting to", votingAddress);

        vm.stopBroadcast();
    }
}
