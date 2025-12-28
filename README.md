# Boundless

## Notes

- Callbacks
  - The marketplace can invoke a callback when a proof has been generated
- Requestors
  - A nice way to allow proof requests in a permissionless way
  - Someone invokes a method on a smart contract that request a proof via the marketplace
  - Boundless checks if the user is allowed to request that proof (via the `isValidSignature` function)
    - if valid, the contract pays the marketplace for the proof

## Idea

I want to do something unique but keep it straightforward and minimalist. Originally, I wanted to do the sealed acuction project as mentioend in the document, but I decided to pivot to a simple voting application when I read about Callbacks and Requestors.

The idea is that members of a community/DAO/.. can vote on a simple proposal and anyone can invoke the tally process through Smart Contract Requestors (that way no single entity has control over when or if to start the tally process). Once Boundless generates the proof of the tally, it invokes a callback in a Solidity contract, provides the proof of the tally and the contract, via the callback, verifies the proof and settles the tally.

The voters only send a commit of their vote to the EVM contract `H(address || choice || proposalID)` where `choice` is `choice ∈ {YES, NO}`. The voting contract stores the commits in a Merkle List (a hashed list) so that the prover can't omit certain votes.

For simplcity, I will omit a bunch of application specific checks but mention them where needed (e.g. check that the deadline has passed before finishing the tally, ..). Additionally, one contract serves for everything: the voting app specific logic, the callback and the smart contract requestor via `isValidSignature` - this is a deliberate design choice to keep thigs minimal and simple.

The end-to-end flow consists of the following interactions with the smart contract:

1. deploy
2. fund the account on boundless
3. call `createProposal`
4. call `castVote` `n` times
5. request boundless to generate a tally proof
6. boundless invokes `isValidSignature` to fund the request
7. after the proof has been generated, boundless calls `handleProof` to submit the tally proof and finish the tally for the proposal

```mermaid
%%{init: {"flowchart": {"nodeSpacing": 120, "rankSpacing": 80}} }%%
flowchart LR
  V[Voters]
  T[Anyone]
  SC[Voting Contract]
  M[Boundless Market]
  Z[zkVM + Prover]
  R[Voting result]

  V -->|cast vote commit| SC
  T -->|submit tally request| M
  M -->|authenticate proof request via isValidSignature| SC
  SC -.->|pay marketplace if valid| M
  M -->|request tally proof| Z
  Z -->|fufill tally proof request| M
  M -->|trigger handleProof callback to settle tally| SC
  SC -->|store result, trigger outcome| R
```

## Quick start

The main entry points are

- `guests/voting-tally/src/main.rs` for the zkVM code
- `apps/src/main.rs` for the interaction with the contract and the marketplace
- `contracts/src/Voting.sol` the contract itself

The contract has been deployed to `0xfAe37883b91f113429C1A16Cd55d37fE62899739` (https://sepolia.etherscan.io/address/0xfAe37883b91f113429C1A16Cd55d37fE62899739) and the marketplace has also been funded with 0.05 ethers. An example proof request can be fund here https://explorer.testnet.boundless.network/orders/0x1fae37883b91f113429c1a16cd55d37fe6289973900000000?from=orders

To redeploy the contract the following must be done:

- specifying a `PRIVATE_KEY` env variable that has enough funds on Sepolia
  - `.env.sepolia` consists of a set of env variables required to run the examples incl. a funded private key
- calling the deploy script to deploy the contract (the script logs the address of the contract, copy the address)
  ```bash
  VERIFIER_ADDRESS="0x925d8331ddc0a1F0d96E68CF073DFE1d92b69187" forge script contracts/scripts/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast -vv
  ```
- fund the contract through boundless marketplace
  ```bash
  cast send "0xfAe37883b91f113429C1A16Cd55d37fE62899739" \
    "depositToBoundlessMarket()" \
    --value 0.05ether \
    --rpc-url "https://ethereum-sepolia-rpc.publicnode.com" \
    --private-key "INSERT_PRIVATE_KEY_HERE"
  ```
- execute the main app to create a proposal, cast votes and trigger a proof request
  ```bash
  RUST_LOG=info cargo run --bin app
  ```

The project can be tested locally via

```
cargo test
forge test
```
