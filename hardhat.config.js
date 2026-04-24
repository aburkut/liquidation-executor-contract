// Hardhat config used ONLY for Sentio private contract verification via the
// @sentio/hardhat-sentio plugin. Production build/test workflow stays on
// Foundry (see foundry.toml) — this file is not intended for regular dev use.
//
// Compiler settings below must stay byte-for-byte identical to foundry.toml:
//   - solc 0.8.24
//   - evmVersion shanghai
//   - optimizer enabled, runs = 1
//   - viaIR = true           (REQUIRED — unlockCallback stack-too-deep otherwise)
//   - bytecodeHash = "none"  (drops CBOR metadata suffix — saves ~53 bytes)
//   - appendCBOR = false
// Divergence here produces a different bytecode and Sentio's verification
// against the on-chain V6 contract would fail.
//
// settings.libraries: pre-links ParaswapDecoderLib so the deployed bytecode in
// SwapLegExecutorLib (and LiquidationExecutor) has the actual address instead of
// the __$...$__ placeholder. Without this Sentio bytecode comparison fails.

require('@sentio/hardhat-sentio');

const PROJECT = process.env.SENTIO_PROJECT || 'a_burkut90/liquidation-bot';

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
    solidity: {
        version: '0.8.24',
        settings: {
            evmVersion: 'shanghai',
            viaIR: true,
            optimizer: {
                enabled: true,
                runs: 1
            },
            metadata: {
                bytecodeHash: 'none',
                appendCBOR: false
            },
            libraries: {
                'src/libraries/ParaswapDecoderLib.sol': {
                    ParaswapDecoderLib: '0x01E0B8e5B4A2A055F6a18B6442d7ecC7BC519a16'
                }
            }
        }
    },
    paths: {
        sources: './src',
        // No tests in Hardhat — Foundry owns the test suite.
        tests: './.hardhat-empty-tests',
        cache: './cache-hardhat',
        artifacts: './artifacts'
    },
    sentio: {
        project: PROJECT
    }
};
