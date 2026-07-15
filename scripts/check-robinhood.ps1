# Smoke-check Robinhood Chain RPC connectivity (Foundry cast).
# Usage: pwsh scripts/check-robinhood.ps1

$ErrorActionPreference = "Stop"

$endpoints = @(
    @{ Name = "robinhood_testnet"; Url = "https://rpc.testnet.chain.robinhood.com"; Expect = 46630 },
    @{ Name = "robinhood_mainnet"; Url = "https://rpc.mainnet.chain.robinhood.com"; Expect = 4663 }
)

foreach ($ep in $endpoints) {
    Write-Host "== $($ep.Name) ==" -ForegroundColor Cyan
    $id = [int](cast chain-id --rpc-url $ep.Url).Trim()
    $block = (cast block-number --rpc-url $ep.Url).Trim()
    if ($id -ne $ep.Expect) {
        throw "Unexpected chain id for $($ep.Name): got $id, expected $($ep.Expect)"
    }
    Write-Host "  chainId=$id  block=$block  OK"
}

Write-Host ""
Write-Host "Named Foundry aliases (foundry.toml):" -ForegroundColor Cyan
cast chain-id --rpc-url robinhood_testnet
cast chain-id --rpc-url robinhood_mainnet

Write-Host ""
Write-Host "Ready. Next: fund a deployer, then:" -ForegroundColor Green
Write-Host '  $env:DEPLOYER_PRIVATE_KEY="0x..."'
Write-Host "  forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast -vvvv"
Write-Host "See docs/robinhood-chain.md"
