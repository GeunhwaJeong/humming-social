// Copyright (c) Haneul Labs
// SPDX-License-Identifier: Apache-2.0

/// Package initializer: claims the `Publisher` and sets up the trading
/// infrastructure for `Username` objects, plus the platform fee
/// config.
///
/// `Username` is the package's tradeable asset, but wallets and
/// marketplaces can only render and trade a type through objects that
/// require publisher authority to create — so this must happen at
/// publish time, in the one place an OTW exists:
/// - `Display<Username>` tells wallets to render a username by its
///   name instead of as a raw object id. The `Display` object goes to
///   the deployer, so fields (e.g. an `image_url` once a renderer
///   exists) can be added later without an upgrade.
/// - A shared `TransferPolicy<Username>` is what kiosk-based
///   marketplaces need to complete a trade. It starts with no rules
///   (free trading); royalty or other rules can be added later with
///   the `TransferPolicyCap`.
/// - The canonical `FeeConfig` (see `humming::platform`) — created
///   here and only here, so every payment path shares one fee lever.
module humming::humming;

use humming::namespace::Username;
use humming::platform;
use sui::display;
use sui::package;
use sui::transfer_policy;

/// Launch fee: 5%. The ceiling (10%) is a compile-time constant in
/// `humming::platform`; the plan is to walk this down over time, with
/// the `FeeConfigCap` eventually handed to governance.
const INITIAL_FEE_BPS: u64 = 500;

/// One-time witness. Claiming the `Publisher` with it is what later
/// authorizes creating `Display` and `TransferPolicy` objects for the
/// types of this package.
public struct HUMMING has drop {}

// share_owned is a false positive here: the policy is created within
// this very call (`transfer_policy::new`), the linter just cannot see
// across the module boundary.
#[allow(lint(share_owned))]
fun init(otw: HUMMING, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);

    let mut display = display::new<Username>(&publisher, ctx);
    display.add(b"name".to_string(), b"@{name}".to_string());
    display.add(
        b"description".to_string(),
        b"Humming username @{name}. Holding this object is ownership of the name.".to_string(),
    );
    display.update_version();

    let (policy, policy_cap) = transfer_policy::new<Username>(&publisher, ctx);
    transfer::public_share_object(policy);

    let deployer = ctx.sender();
    // Also delivers the `FeeConfigCap` to the deployer: the cap is
    // `key`-only, so only its defining module can move it.
    platform::new(INITIAL_FEE_BPS, deployer, ctx);

    transfer::public_transfer(publisher, deployer);
    transfer::public_transfer(display, deployer);
    transfer::public_transfer(policy_cap, deployer);
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(HUMMING {}, ctx);
}
