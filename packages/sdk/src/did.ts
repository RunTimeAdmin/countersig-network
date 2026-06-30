import { ethers } from 'ethers';

export interface ParsedDid {
  chainId: number;
  agentAddress: string;
}

export function parseDid(did: string): ParsedDid {
  const match = did.match(/^did:countersig:(\d+):(0x[0-9a-fA-F]{40})$/);
  if (!match) throw new Error(`Invalid did:countersig format: ${did}`);
  return { chainId: parseInt(match[1], 10), agentAddress: match[2] };
}

export function formatDid(agentAddress: string, chainId: number | bigint): string {
  return `did:countersig:${chainId}:${agentAddress.toLowerCase()}`;
}

// Replicates the Solidity on-chain derivation:
//   keccak256(abi.encodePacked("did:countersig:", block.chainid, ":", agentAddress))
// Any party can reproduce this without querying the contract.
export function computeDidHash(agentAddress: string, chainId: number | bigint): string {
  return ethers.keccak256(
    ethers.solidityPacked(
      ['string', 'uint256', 'string', 'address'],
      ['did:countersig:', BigInt(chainId), ':', agentAddress]
    )
  );
}
