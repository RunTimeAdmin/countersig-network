declare module 'tweetnacl' {
  const nacl: {
    randomBytes(length: number): Uint8Array;
    sign: {
      keyPair: {
        (): { publicKey: Uint8Array; secretKey: Uint8Array };
        fromSeed(seed: Uint8Array): { publicKey: Uint8Array; secretKey: Uint8Array };
      };
      detached: {
        (message: Uint8Array, secretKey: Uint8Array): Uint8Array;
        verify(message: Uint8Array, signature: Uint8Array, publicKey: Uint8Array): boolean;
      };
    };
  };
  export = nacl;
}
