import { Wallet } from 'ethers';

const w = Wallet.createRandom();

console.log('address:', w.address);

console.log('privateKey:', w.privateKey);
