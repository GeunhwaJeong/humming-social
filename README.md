# humming — social primitives on Move

On-chain social primitives for Sui: usernames, follow graphs, feeds,
groups, subscriptions, and paywalls, tied together by a composable rule
framework. The package decomposes into small primitives
that each own their state, with access policies attached as rules, and
every mechanism is built natively on the Move object model.

```
sources/
├── humming.move        Package init: Publisher, Display, TransferPolicy, FeeConfig
├── platform.move       Platform fee: one canonical lever, 5% hard ceiling
├── rules.move          Rule framework (hot-potato receipts, RuleSet objects)
├── namespace.move      Username registry + transferable Username objects
├── graph.move          Follow graph (graph-level + per-account follow rules)
├── feed.move           Posts: reply / quote / repost, per-post reply rules
├── group.move          Memberships, admin management, bans
├── profile.move        Optional profile metadata object
├── subscriptions.move  Prepaid extendable subscriptions (the Patreon primitive)
├── paid_posts.move     Per-post paywalls (pay once to unlock)
├── tips.move           Tips to a creator or post, with an indexable event trail
├── creator_prefs.move  Creator-owned serving preferences (e.g. subscriber-only profile)
└── rule_impls/
    ├── simple_payment_rule.move      Paid follow/join/post (any coin type)
    ├── token_gated_rule.move         Token-gated interactions (point-in-time)
    ├── locked_token_rule.move        Flash-proof token gate (time-locked, soulbound)
    ├── username_validation_rule.move Length + charset validation
    ├── followers_only_rule.move      Followers-only replies
    └── subscriber_only_rule.move     Active-subscriber-only interactions
tests/
├── test_helpers.move   Shared scenario fixtures
└── *_tests.move        13 per-module suites, 110 scenario tests (all passing)
```

## Deployments

Live on Sui mainnet (chain id `35834a8a`), published as package
version 1 in transaction
[`C7jTGgV4iSKBYvR2WiSYW5EmKtazMm6UCBKNsRcfAJFF`](https://suiscan.xyz/mainnet/tx/C7jTGgV4iSKBYvR2WiSYW5EmKtazMm6UCBKNsRcfAJFF).

| Object | ID |
|--------|----|
| Package | [`0xab4b13423a5f6d06d0c674d34cffcc3ef608b3ecf8995c046ddd08c5f1e02cec`](https://suiscan.xyz/mainnet/object/0xab4b13423a5f6d06d0c674d34cffcc3ef608b3ecf8995c046ddd08c5f1e02cec) |
| `Feed` (shared) | [`0xd0f89f42e610e92085e49798e77c61415576562e2ddac3c498746ffa812d2a71`](https://suiscan.xyz/mainnet/object/0xd0f89f42e610e92085e49798e77c61415576562e2ddac3c498746ffa812d2a71) |
| `RuleSet<CreatePostOp>` (shared) | [`0xa115c8a771b498221d7f37e56e6fda420850ab9159cfbeed3dcf9782370d23df`](https://suiscan.xyz/mainnet/object/0xa115c8a771b498221d7f37e56e6fda420850ab9159cfbeed3dcf9782370d23df) |
| `FeeConfig` (shared) | [`0xfdc95259beccc716d344a79be87681c2c65f102d7630e0d92ec118c418e2fe22`](https://suiscan.xyz/mainnet/object/0xfdc95259beccc716d344a79be87681c2c65f102d7630e0d92ec118c418e2fe22) |
| `PrefsRegistry` (shared) | [`0xe3c914089b09a0cae4fb0142e3a76244d492cf6c779fd2ccb09c10fdf4e069dd`](https://suiscan.xyz/mainnet/object/0xe3c914089b09a0cae4fb0142e3a76244d492cf6c779fd2ccb09c10fdf4e069dd) |

Machine-readable publish metadata for the Sui deployments (mainnet and
testnet) is kept in [`Published.toml`](Published.toml), which is what
`sui client upgrade` reads. The package was first published on the
Haneul object chain; that deployment's metadata is preserved in
[`haneul-mainnet.published.toml`](haneul-mainnet.published.toml) and its
source tree on the `haneul` branch and the `haneul-mainnet-final` tag.

## Built on the object model

- **Primitives are shared objects.** `Namespace`, `Graph`, `Feed`, and
  `Group` each hold their state in nested `Table`s; post ids are
  feed-local and sequential.
- **Usernames are owned objects.** A `Username` is a transferable object
  minted from the `Namespace` registry, so names trade like any other
  asset.
- **Accounts are native.** The address is the identity; an optional
  `Profile` object carries metadata. No smart-wallet contract layer.
- **Rules are hot-potato receipts.** `Request<OP>` receipts stamped by
  rule modules replace dynamic dispatch; `RuleSet<OP>` is a standalone
  shared object (Kiosk-style) with required and any-of chaining.
- **Everything else comes from the platform.** Package upgrades are
  native, dynamic fields cover extra key-value storage, PTB
  composability replaces an action registry, and transaction
  authorization replaces typed off-chain signatures.

## The rule system

Move has no dynamic dispatch, so rule enforcement is built on
**hot-potato receipts** (the `sui::transfer_policy` pattern,
hardened):

1. `request_*` on a primitive returns a primitive-specific **ticket** and a
   generic `Request<OP>` hot potato (paired by a per-transaction key).
2. Rule modules validate and **stamp** the request. A stamp records the rule
   type **and the `RuleSet` object ID it was validated against** — a stamp
   earned against account A's cheap follow fee can never satisfy account B's
   expensive one, and validating username X can never authorize minting Y
   (key pairing).
3. `execute_*` confirms every configured *required* rule is stamped (and at
   least one *any-of* rule, if any are configured) before committing state.

`RuleSet<OP>` is a standalone shared object rather than a field inside the
primitive because PTBs cannot pass references returned from calls — but they
can pass shared objects straight into rule modules. Administration is gated
by `RuleSetCap` (mirroring `TransferPolicyCap`).

Example PTB — paid follow (target has a payment rule):

```
r0: (ticket, req) = graph::request_follow(graph, target)
     simple_payment_rule::pay<FollowOp, SUI>(target_rules, &mut req, &mut coin)  // fee split off, change kept
     graph::execute_follow_gated(graph, graph_rules, target_rules, ticket, req, clock)
```

## Deliberate design decisions

- **No smart-wallet account layer.** EVM social protocols need contract
  wallets because EOAs can't hold logic; here the address is the
  identity. Account-manager delegation belongs to wallet infra
  (multisig / sponsored txs), not the protocol.
- **No third-party action registry.** Third-party modules compose with
  the primitives directly in PTBs; tipping is just a coin transfer
  command.
- **Quotes/reposts don't check parent post rules** (replies do). Easy to
  extend via a second `make_parent_request` path if needed.
- **No per-follow id objects.** Reusable follow ids only matter for
  follow-NFT semantics; `Username`-style objects can be added later if
  follow NFTs are wanted.
- **Token-gated rule is a point-in-time possession proof**, same guarantee
  as the EVM `balanceOf` check it mirrors — meaning it can be satisfied
  with funds borrowed and returned inside one transaction. For gates
  where that matters, `locked_token_rule` requires the coins to sit in a
  time-locked deposit that every proof re-extends, so borrowed funds
  cannot qualify.
- **Group bans are built into the primitive** rather than shipped as a
  separate rule module.

## Design history

Changes made in the first hardening round on top of the initial
implementation, and why.

### 1. `simple_payment_rule::pay` — double-charge fix + change-making

The initial version consumed an exact-amount `Coin<T>` and stamped the
request. Two problems:

- **Double charge**: `add_approval` is idempotent (a second stamp is a
  silent no-op) but the coin transfer is not — calling `pay` twice on
  one request took a second full payment and gave nothing back. Fixed
  by adding `rules::has_approval` and aborting with `EAlreadyPaid`
  before touching funds. Rule of thumb: *a proof may be idempotent, a
  payment never silently so.*
- **Ergonomics**: requiring the exact amount forced callers to pre-split
  coins. `pay` now takes `&mut Coin<T>` and splits the fee off itself
  (standard Sui payment shape), so a PTB can pass any sufficiently
  large coin — including the gas coin — and keep the change.

### 2. `locked_token_rule` — flash-proof token gating (new module)

`token_gated_rule` proves possession at a point in time, the same
guarantee as the EVM `balanceOf` check it mirrors — so it can be
satisfied with funds borrowed and returned within one transaction. For
gates where that matters, this module requires coins to sit in a
`Lock<T>` whose release time every successful proof extends by
`min_lock_ms`. Borrowed funds cannot qualify: they could not be
returned within the lending transaction. One lock serves any number of
gates over the same coin type, so capital is committed once, not per
gate.

### 3. `Lock` owner binding — `store` removed (review finding)

Review of (2) found a delegation hole: `Lock` originally had
`key + store`, so a third party could build a shared "lock pool"
wrapper object holding locks, letting **anyone** the pool admits prove
with someone else's locked capital — defeating the point of the gate.

Two candidate fixes were considered:

- *Owner field + assert*: record `owner: address` at creation and check
  it in `prove`. Rejected: it keeps composability but any future
  `rebind` function (needed if locks are ever transferred) reopens the
  hole from inside the pool wrapper, and an owner field must be
  maintained forever.
- *Drop `store` (chosen)*: with `key` only, a `Lock` cannot be wrapped
  into another object or moved with `public_transfer` — the object
  system itself guarantees that whoever passes `&mut Lock` to `prove`
  owns it, and a request's account is always the transaction sender.
  Ownership does the access control; there is no field to manage and
  no rebind to get wrong. Non-transferability is not a loss here — a
  soulbound stake is exactly the semantics a sybil/flash-resistant
  gate wants, and the *funds* become freely movable again through
  `withdraw` once the lock expires.

Because PTBs cannot `TransferObjects` a `store`-less object, the module
gained `keep(lock, ctx)` so the whole
`new_lock → deposit → prove → execute_join → keep` flow still fits in
a single transaction.

### 4. `feed::delete_post` clears `content_uri`

A deleted post used to keep its content pointer in live state. It is
now emptied on deletion: deletion should stop advertising the content
(and the freed bytes earn a storage rebate). Note this cannot erase
history — past events and object versions still contain the URI.

### 5. `Lock` lifecycle events

Every primitive in the package emits events, but the rule modules were
silent — defensibly so for `simple_payment_rule` (its effect is a coin
transfer, which the chain already records natively) but not for
`locked_token_rule`: a `Lock` is module-owned persistent state whose
single most important question — *"when can I withdraw?"* — was
unanswerable off-chain without polling the object. Added:

- `LockCreated { lock, owner }` — because the lock is soulbound, this
  one event determines ownership for the object's entire lifetime; an
  indexer never needs to track transfers.
- `Deposited` / `Withdrawn` `{ lock, amount, balance }` — carry the
  **post-change balance** so indexers reconstruct state from the event
  stream alone, no state reads.
- `LockExtended { lock, set, unlock_ms }` — emitted by `prove` **only
  when the release time actually moves**: the event stream mirrors
  state changes, not proof attempts (a proof that doesn't extend the
  lock is not an interesting fact for a wallet, and which gate extended
  it is captured in `set`). This only-on-change semantic is pinned by a
  test.
- `LockDestroyed { lock }` — closes the lifecycle.

### 6. Adversarial test round (20 → 31 tests)

The new tests pin the security invariants rather than the happy path:
double-pay aborts; a stamp bought against one rule set cannot satisfy
another (set-ID binding); a foreign rule set object is rejected;
ticket/request key mismatches are rejected; a removed rule is no longer
enforced; an assigned username cannot be burned; a username buyer can
unassign and reassign; deleting a post clears content; locked-token
join, early-withdraw rejection, and insufficient-lock rejection.

### 7. Package init: `Publisher`, `Display`, `TransferPolicy` (review finding)

The package had no one-time witness, which quietly forecloses the
product story around usernames: without an OTW there is no
`Publisher`, without a `Publisher` there is no `Display<Username>`
(wallets render the "tradeable name" as a bare object id) and no
`TransferPolicy<Username>` (kiosk-based marketplaces refuse to trade
the type at all). And publish time is the only chance to get an OTW —
recovering one later means shipping a new module in an upgrade.

`humming.move` now claims the `Publisher` in `init`, creates a
`Display<Username>` rendering `@{name}` (updatable later through the
owned `Display` object, e.g. to add an `image_url`), and shares an
empty `TransferPolicy<Username>` — free trading now, royalty rules
addable later with the retained cap. Two tests pin it (31 → 33): the
init artifacts land where they should, and a full kiosk cycle —
rule-gated mint → list → purchase through the shared policy → seller
withdraws proceeds.

### 8. Rule-framework coverage round: any-of & administration (33 → 41 tests)

Half of the rule semantics — the *any-of* quota — and every
administration error path in `rules.move` had no test at all. Eight
tests close that: either any-of rule admits on its own; an empty stamp
set aborts; a required stamp does not count toward the any-of quota
**and vice versa** (the two quotas are independent by construction, and
now by test); duplicate adds abort even under the other requiredness;
a cap cannot administer a foreign rule set; removing a never-added rule
aborts; and `MAX_RULES` counts required + any-of together (a test-only
`FillerRule<phantom T>` witness supplies 21 distinct rule identities).

### 9. Shared-object versioning (pre-publish deadline)

Published package versions stay callable forever: after an upgrade
fixes a bug, nothing stops clients from keeping their writes on the old
code — unless the shared objects themselves refuse it. Every shared
object (`Namespace`, `Graph`, `Feed`, `Group`, `RuleSet`) now carries a
`version: u64`, checked at the top of every mutating entry point and
interaction start. The constant lives in one place (`rules::VERSION`,
read by the primitives via `current_version()`), so a single bump in an
upgrade bricks all stale writes at once; each object's admin then runs
`migrate` (cap-gated, rejects same-version calls) to re-enable it.
Struct layouts cannot change after publish, which is why the field had
to land now. Rule-set read/stamp paths are deliberately not gated:
stamps only matter to `confirm`, which primitives reach behind their
own version gates. Eight tests (41 → 49) pin the gate on every object
type and the migrate round-trip.

### 10. Monetization layer: platform fee, subscriptions, paid posts

Three modules turn the social primitives into a creator-monetization
protocol. All of them keep the package's division of labor: the chain
records *who paid for what*; the app decides what that access renders.

- **`platform`** — the single fee lever. `new` is package-internal and
  called once from `init`, so a `&FeeConfig` parameter can only ever
  be the canonical object: a zero-fee lookalike cannot be wired into a
  payment path. `MAX_FEE_BPS` (5%) is a compile-time ceiling no cap
  holder can cross — creators price against a bounded worst case, not
  an announcement. The launch fee is 0%; it can be raised later through
  the cap but never past the ceiling, and because the lever is an
  ordinary transferable `FeeConfigCap`, handing it to a governance
  contract later is a transfer, not an upgrade. Note that a
  compile-time ceiling is only as strong as the package's upgrade
  policy: keep the `UpgradeCap` under a restrictive policy (or make the
  package immutable) once the deployment settles, otherwise an upgrade
  could raise the constant. Fee math uses a u128 intermediate (u64 `amount * bps`
  overflows well inside the coin supply) and floors in the creator's
  favor.
- **`subscriptions`** — the Patreon primitive. An object chain has no
  pull payments, so a "recurring" subscription is a prepaid,
  extendable expiry: paying extends an active subscription from its
  expiry (periods stack), a lapsed one restarts from now, and lapsing
  itself needs no transaction at all. `subscriber_only_rule` bridges
  tiers into the rule framework (subscriber-only replies, follows,
  joins). Anyone can pay for any beneficiary — gift subscriptions
  come free with the design.
- **`paid_posts`** — per-post paywalls. A paywall cannot withhold
  bytes (`content_uri` is public state); it is the canonical purchase
  record the app serves full content against. One paywall per post,
  enforced by a registry in the `Feed`; the paywall itself is a
  per-post shared object, so purchases of different posts never
  contend. Reposts cannot be paywalled (no content of their own), and
  deleted posts stop selling.

`simple_payment_rule` now routes through `platform::collect` as well,
so every payment path shares the one fee lever. Thirteen tests (49 → 62) pin the fee split on every path, the ceiling,
the walk-to-zero flow, subscription stacking/lapse/re-subscribe/gift,
the subscriber-gated reply E2E, and every paywall error path.

### 11. Second review round: multi-tier gates, price guards, purchase snapshots

An independent review of the monetization layer surfaced three
product-level findings, fixed here (62 → 68 tests):

- **Multi-tier access could not be expressed.** Rule identity is the
  witness type name, so a rule cannot be attached to one rule set
  twice — and `subscriber_only_rule`'s config held a single tier ID,
  making "silver OR gold subscribers" (the basic Patreon shape)
  impossible. The config now holds a `vector<ID>` of accepted tiers:
  one instance, any-of-these-tiers semantics. `token_gated_rule`
  had the same limitation across coin types; its witness is now
  generic over the coin (`TokenGatedRule<T>`), so "hold coin X OR
  coin Y" is two any-of entries in one set.
- **No price guard.** `subscribe`, `purchase`, and `pay` all read the
  live price, so a creator's price change landing before a buyer's
  transaction silently charged the new price (the common wallet habit
  of passing a large coin makes this real). All three now take the
  `expected_price`/`expected_amount` the payer saw when signing and
  abort on mismatch.
- **Paywalled content could be swapped after purchase.** The author
  can still edit (deliberately — typo fixes are legitimate), but
  `PostPurchased` now snapshots the post's `content_uri` at purchase
  time: on-chain evidence of what was sold, and what the app should
  keep serving to that buyer in a dispute.

## Build & test

```bash
sui move build --build-env mainnet
sui move test --build-env mainnet   # 110 tests
```

## License

Apache-2.0.
