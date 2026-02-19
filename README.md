# SSUI Token (SuperSui Token)

Sui Move smart contract for the **SSUI** token. Token only — no matrix or presale logic.

- **Module:** `ssui::ssui`
- **Token type:** `ssui::ssui::SSUI`
- **Decimals:** 9 (1 SSUI = 10^9 raw units)
- **Total supply:** 10.1B (10B to creator, 100M contract pool)

## Clone & build

```bash
git clone https://github.com/YOUR_USERNAME/ssui-token.git
cd ssui-token
sui move build
```

## Publish

```bash
sui move publish --gas-budget 100000000
```

Requires [Sui CLI](https://docs.sui.io/build/install) and a funded address.

## Contents

| Path | Description |
|------|-------------|
| `sources/ssui.move` | Token: mint/burn, transfers, fees, admin, authorized minters |
| `Move.toml` | Package config (address `ssui`) |

## License

See repository license.
