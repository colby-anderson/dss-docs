// SPDX-License-Identifier: AGPL-3.0-or-later

/// vat.sol -- Dai CDP database

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.12;

// FIXME: This contract was altered compared to the production version.
// It doesn't use LibNote anymore.
// New deployments of this contract will need to include custom events (TO DO).

contract Vat {
    // --- Auth ---
    // seems like there should be more complex auth since some contracts only call other
    // contracts' functions. more modular
    mapping (address => uint) public wards;
    function rely(address usr) external auth { require(live == 1, "Vat/not-live"); wards[usr] = 1; }
    function deny(address usr) external auth { require(live == 1, "Vat/not-live"); wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "Vat/not-authorized");
        _;
    }

    mapping(address => mapping (address => uint)) public can;
    function hope(address usr) external { can[msg.sender][usr] = 1; }
    function nope(address usr) external { can[msg.sender][usr] = 0; }
    function wish(address bit, address usr) internal view returns (bool) {
        return either(bit == usr, can[bit][usr] == 1);
    }

    // --- Data ---
    struct Ilk {
        uint256 Art;   // Total Normalised Debt     [wad]
        uint256 rate;  // Accumulated Rates         [ray]
        uint256 spot;  // Price with Safety Margin  [ray]
        uint256 line;  // Debt Ceiling              [rad]
        uint256 dust;  // Urn Debt Floor            [rad]
    }
    struct Urn {
        uint256 ink;   // Locked Collateral  [wad]
        uint256 art;   // Normalised Debt    [wad]
    }

    mapping (bytes32 => Ilk)                       public ilks;
    mapping (bytes32 => mapping (address => Urn )) public urns;
    mapping (bytes32 => mapping (address => uint)) public gem;  // [wad]
    mapping (address => uint256)                   public dai;  // [rad]
    mapping (address => uint256)                   public sin;  // [rad]

    uint256 public debt;  // Total Dai Issued    [rad]
    uint256 public vice;  // Total Unbacked Dai  [rad]
    uint256 public Line;  // Total Debt Ceiling  [rad]
    uint256 public live;  // Active Flag

    // --- Init ---
    constructor() public {
        wards[msg.sender] = 1;
        live = 1;
    }

    // --- Math ---
    function add(uint x, int y) internal pure returns (uint z) {
        z = x + uint(y);
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }
    function sub(uint x, int y) internal pure returns (uint z) {
        z = x - uint(y);
        require(y <= 0 || z <= x);
        require(y >= 0 || z >= x);
    }
    function mul(uint x, int y) internal pure returns (int z) {
        z = int(x) * y;
        require(int(x) >= 0);
        require(y == 0 || z / y == int(x));
    }
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Administration ---
    function init(bytes32 ilk) external auth {
        require(ilks[ilk].rate == 0, "Vat/ilk-already-init");
        ilks[ilk].rate = 10 ** 27;
    }
    function file(bytes32 what, uint data) external auth {
        require(live == 1, "Vat/not-live");
        if (what == "Line") Line = data;
        else revert("Vat/file-unrecognized-param");
    }
    function file(bytes32 ilk, bytes32 what, uint data) external auth {
        require(live == 1, "Vat/not-live");
        if (what == "spot") ilks[ilk].spot = data;
        else if (what == "line") ilks[ilk].line = data;
        else if (what == "dust") ilks[ilk].dust = data;
        else revert("Vat/file-unrecognized-param");
    }
    function cage() external auth {
        live = 0;
    }

    // --- Fungibility ---
    function slip(bytes32 ilk, address usr, int256 wad) external auth {
        gem[ilk][usr] = add(gem[ilk][usr], wad);
    }
    function flux(bytes32 ilk, address src, address dst, uint256 wad) external {
        require(wish(src, msg.sender), "Vat/not-allowed");
        gem[ilk][src] = sub(gem[ilk][src], wad);
        gem[ilk][dst] = add(gem[ilk][dst], wad);
    }
    function move(address src, address dst, uint256 rad) external {
        require(wish(src, msg.sender), "Vat/not-allowed");
        dai[src] = sub(dai[src], rad);
        dai[dst] = add(dai[dst], rad);
    }

    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- CDP Manipulation ---

    // frob
    //
    // DESCRIPTION:
    // frob modifies an urn by adding gem (collateral) to the urn,
    // thereby generating dai.
    //
    // PARAMETERS:
    // bytes32  i       the type of collateral in the urn
    // address  u       the user who owns the urn
    // address  v       the user supplying the collateral (gem)
    // address  w       the user receiving the generated dai
    // int      dink    the amount of collateral being added to the urn
    // int      dart    the amount of dai being generated
    function frob(bytes32 i, address u, address v, address w, int dink, int dart) external {
        require(live == 1, "Vat/not-live"); // system must be live

        Urn memory urn = urns[i][u]; // the urn being modified
        Ilk memory ilk = ilks[i]; // the type of the collateral being added to the urn

        require(ilk.rate != 0, "Vat/ilk-not-init"); // the ilk must have been previously init-ed

        urn.ink = add(urn.ink, dink); // adding the collateral to the urn
        urn.art = add(urn.art, dart); // adding the amount of debt to the urn
        ilk.Art = add(ilk.Art, dart); // adding the amount of debt globally

        //??? Is the rate added on every time money is withdrawn or added to urn????
        int dtab = mul(ilk.rate, dart); // the amount of debt added to the urn (in stablecoin)
        uint tab = mul(ilk.rate, urn.art); // the amount of debt in the urn (in stablecoin)
        debt     = add(debt, dtab); // adding the amount of new debt (in stablecoin) to the total debt

        // The amount of dai being generated must be negative (returning dai)
        // or the amount of debt (with the new debt added) must be less than the debt ceiling for that
        // particular collateral type. The total system debt must be less than the total
        // debt ceiling as well.
        require(either(dart <= 0, both(mul(ilk.Art, ilk.rate) <= ilk.line, debt <= Line)), "Vat/ceiling-exceeded");

        // Either the new debt in the urn must be less and the collateral must be larger  (WHY?)
        // or the amount of debt (in stablecoin) must be less than the urn's amount of collateral (in stablecoin)
        require(either(both(dart <= 0, dink >= 0), tab <= mul(urn.ink, ilk.spot)), "Vat/not-safe");

        // urn is either more safe, or the owner consents
        require(either(both(dart <= 0, dink >= 0), wish(u, msg.sender)), "Vat/not-allowed-u");
        // collateral src consents
        require(either(dink <= 0, wish(v, msg.sender)), "Vat/not-allowed-v");
        // debt dst consents
        require(either(dart >= 0, wish(w, msg.sender)), "Vat/not-allowed-w");

        // Makes sure that the urn's debt is 0 or that it is over the
        // minimum amount of required debt for that specific collateral type
        require(either(urn.art == 0, tab >= ilk.dust), "Vat/dust");

        // subtracts the collateral from the gem, since gem is unencumbered
        // and now this collateral is encumbered.
        gem[i][v] = sub(gem[i][v], dink);

        // add the newly generated dai for the particular user w
        dai[w]    = add(dai[w],    dtab);

        urns[i][u] = urn;
        ilks[i]    = ilk;
    }

    // --- CDP Fungibility ---


    // fork
    //
    // DESCRIPTION:
    // fork moves a certain amount of collateral and debt from one vault
    // to another.
    //
    // PARAMETERS:
    // bytes32  ilk      the type of collateral in the urn
    // address  src      the user who owns the urn
    // address  dst      the user who owns the urn that is receiving
    // int      dink     the amount of collateral being added to the urn
    // int      dart     the amount of dai being generated
    function fork(bytes32 ilk, address src, address dst, int dink, int dart) external {
        Urn storage u = urns[ilk][src];
        Urn storage v = urns[ilk][dst];
        Ilk storage i = ilks[ilk];

        u.ink = sub(u.ink, dink);
        u.art = sub(u.art, dart);
        v.ink = add(v.ink, dink);
        v.art = add(v.art, dart);

        uint utab = mul(u.art, i.rate); // the amount of debt in stablecoin for the src urn
        uint vtab = mul(v.art, i.rate); // amt of debt in stablecoin for dst urn

        // both sides consent
        require(both(wish(src, msg.sender), wish(dst, msg.sender)), "Vat/not-allowed");

        // both sides safe
        require(utab <= mul(u.ink, i.spot), "Vat/not-safe-src");
        require(vtab <= mul(v.ink, i.spot), "Vat/not-safe-dst");

        // both sides non-dusty
        require(either(utab >= i.dust, u.art == 0), "Vat/dust-src");
        require(either(vtab >= i.dust, v.art == 0), "Vat/dust-dst");

        // Doesn't need to check debt ceiling since no new collateral is being locked
    }


    // --- CDP Confiscation ---

    // grab
    //
    // DESCRIPTION:
    // grab moves a certain amount of collateral and debt from one vault
    // to another.
    //
    // PARAMETERS:
    // bytes32  i      the type of collateral in the urn
    // address  u      the user who owns the urn
    // address  v      the user who gets the collateral
    // address  w      creates sin for this user
    // int      dink
    // int      dart
    function grab(bytes32 i, address u, address v, address w, int dink, int dart) external auth {
        Urn storage urn = urns[i][u];
        Ilk storage ilk = ilks[i];

        urn.ink = add(urn.ink, dink); // should be subtracting the collateral
        urn.art = add(urn.art, dart); // should be subtracting the debt
        ilk.Art = add(ilk.Art, dart); // should be subtracting the global debt

        int dtab = mul(ilk.rate, dart); // calculating how much the user needs to pay

        gem[i][v] = sub(gem[i][v], dink); // should be adding the collateral back to gem
        sin[w]    = sub(sin[w],    dtab); // adds the debt to the sin for the particular usr who took out the dai
        vice      = sub(vice,      dtab); // adds the debt to the vice
    }

    // --- Settlement ---
    // destorys dai and system debt
    // rad is the amount to destroy
    // cancels out the debt for msg.sender
    // called by the vow in vow.heal
    function heal(uint rad) external {
        address u = msg.sender;
        sin[u] = sub(sin[u], rad);
        dai[u] = sub(dai[u], rad);
        vice   = sub(vice,   rad);
        debt   = sub(debt,   rad);
    }

    // creates sin (WHY??)
    function suck(address u, address v, uint rad) external auth {
        sin[u] = add(sin[u], rad);
        dai[v] = add(dai[v], rad);
        vice   = add(vice,   rad);
        debt   = add(debt,   rad);
    }


    // --- Rates ---
    function fold(bytes32 i, address u, int rate) external auth {
        require(live == 1, "Vat/not-live");
        Ilk storage ilk = ilks[i];
        ilk.rate = add(ilk.rate, rate);
        int rad  = mul(ilk.Art, rate);
        dai[u]   = add(dai[u], rad);
        debt     = add(debt,   rad);
    }
}
