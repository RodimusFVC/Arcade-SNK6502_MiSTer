//============================================================================
//  SNK6502 FPGA Core
//
//  Supports: Sasuke vs. Commander, Satan of Saturn / Zarzon, Vanguard,
//            Fantasy, Pioneer Balloon, Nibbler
//
//  Phase 05: Address decode, I/O registers, inputs, NMI
//============================================================================

module snk6502(
    input         clk_master,     // 11.289 MHz master clock
    input         reset,
    input         pause,
    output        ce_pix,

    // Game configuration (selects memory map / I/O layout)
    input  [3:0]  game_id,        // which game variant (see defines below)

    // DEBUG outputs (active accent on accent removal)
    output [3:0]  dbg_game_id,
    output        dbg_crtc_hit,
    output        dbg_cpu_active,

    // Player inputs
    input  [7:0]  in0,            // IN0 port
    input  [7:0]  in1,            // IN1 port
    input  [7:0]  in2,            // IN2 port (coins, starts)
    input  [7:0]  dsw,            // DIP switches

    // ROM download interface
    input  [16:0] dn_addr,
    input  [7:0]  dn_data,
    input         dn_wr,

    // Video output
    output [7:0]  rgb_r,
    output [7:0]  rgb_g,
    output [7:0]  rgb_b,
    output        hsync,
    output        vsync,
    output        hblank,
    output        vblank,

    // Audio output (stub)
    output [15:0] audio,

    // Screen flip output
    output        flip_screen
);

// Game IDs
localparam GID_SASUKE   = 4'd0;
localparam GID_SATANSAT = 4'd1;
localparam GID_VANGUARD = 4'd2;
localparam GID_FANTASY  = 4'd3;
localparam GID_PBALLOON = 4'd4;
localparam GID_NIBBLER  = 4'd5;

// I/O region base address varies by game
// Vanguard:        $31xx (reads at $3104-$3107)
// Fantasy:         $21xx
// PBalloon:        $B1xx
// Sasuke/SatanSat: $B0xx (different register layout)

// ---------------------------------------------------------------------------
// ROM download address decoding
// Layout: $00000-$0FFFF = maincpu (64K), $10000-$11FFF = gfx1 (8K),
//         $12000-$1203F = proms (64 bytes), $12040-$137FF = sound ROM (6K)
wire dn_maincpu = (dn_addr[16:16] == 1'b0);                    // $00000-$0FFFF
wire dn_gfx1    = (dn_addr[16:13] == 4'b1_000);                // $10000-$11FFF
wire dn_proms   = (dn_addr[16:6]  == 11'b1_0010_0000_00);      // $12000-$1203F
wire dn_sndrom  = (dn_addr[16:13] == 4'b1_001) & ~dn_proms;    // $12040-$13FFF

// ---------------------------------------------------------------------------
// Clock generation
// ---------------------------------------------------------------------------
reg [3:0] clk_div;
always @(posedge clk_master or posedge reset)
    if (reset)
        clk_div <= 4'd0;
    else
        clk_div <= clk_div + 4'd1;

wire crtc_clken = (clk_div == 4'd15);

wire is_slow_cpu = (game_id == GID_SASUKE) || (game_id == GID_SATANSAT);
wire cpu_clken   = is_slow_cpu ? crtc_clken : (clk_div[2:0] == 3'd7);

// ---------------------------------------------------------------------------
// Reset logic
// ---------------------------------------------------------------------------
reg [7:0] reset_cnt;
reg       cpu_reset;
wire      cpu_reset_n = ~cpu_reset;

always @(posedge clk_master)
    if (reset) begin
        cpu_reset <= 1'b1;
        reset_cnt <= 8'd0;
    end else begin
        if (reset_cnt != 8'h10)
            reset_cnt <= reset_cnt + 8'd1;
        else
            cpu_reset <= 1'b0;
    end

// ---------------------------------------------------------------------------
// CPU instantiation (T65 - 6502 mode)
// ---------------------------------------------------------------------------
wire [15:0] cpu_addr;
wire [7:0]  cpu_din;
wire [7:0]  cpu_dout;
wire        cpu_rw_n;
wire        cpu_nmi_n;

wire cpu_rdy;
wire is_highmem_read = cpu_rw_n & (cpu_addr[15:14] != 2'b00);
wire needs_wait = ~is_slow_cpu & is_highmem_read;

reg wait_state;
always @(posedge clk_master or posedge reset)
    if (reset)
        wait_state <= 1'b0;
    else if (cpu_clken)
        wait_state <= needs_wait & ~wait_state;

assign cpu_rdy = ~pause & ~(needs_wait & ~wait_state);

T65 cpu(
    .mode   (2'b00),
    .res_n  (cpu_reset_n),
    .enable (cpu_clken),
    .clk    (clk_master),
    .rdy    (cpu_rdy),
    .abort_n(1'b1),
    .irq_n  (cpu_irq_n),
    .nmi_n  (cpu_nmi_n),
    .so_n   (1'b1),
    .r_w_n  (cpu_rw_n),
    .a      (cpu_addr),
    .di     (cpu_din),
    .do     (cpu_dout)
);

// ---------------------------------------------------------------------------
// Program ROM - 64KB (sparse, loaded by .mra at correct addresses)
// ---------------------------------------------------------------------------
wire [7:0] rom_dout;

dpram #(.address_width(16)) prog_rom(
    .clock_a  (clk_master),
    .enable_a (1'b1),
    .wren_a   (dn_wr & dn_maincpu),
    .address_a(dn_addr[15:0]),
    .data_a   (dn_data),
    .q_a      (),

    .clock_b  (clk_master),
    .enable_b (1'b1),
    .wren_b   (1'b0),
    .address_b(cpu_addr),
    .data_b   (8'd0),
    .q_b      (rom_dout)
);

// ---------------------------------------------------------------------------
// Work RAM - 1KB at $0000-$03FF
// ---------------------------------------------------------------------------
wire ram_cs = (cpu_addr[15:10] == 6'b000000);
wire [7:0] ram_dout;
wire ram_wr = ram_cs & ~cpu_rw_n;

spram #(.address_width(10)) work_ram(
    .clock  (clk_master),
    .enable (cpu_clken & ram_cs),
    .wren   (ram_wr),
    .address(cpu_addr[9:0]),
    .data   (cpu_dout),
    .q      (ram_dout)
);

// ---------------------------------------------------------------------------
// Video RAM 2 (foreground tilemap) - 1KB at $0400-$07FF
// ---------------------------------------------------------------------------
wire vram2_cs = (cpu_addr[15:10] == 6'b000001);
wire [7:0] vram2_cpu_dout;
wire vram2_wr = vram2_cs & ~cpu_rw_n;

wire [9:0] vram2_vid_addr;
wire [7:0] vram2_vid_dout;

dpram #(.address_width(10)) vram2(
    .clock_a  (clk_master),
    .enable_a (cpu_clken),
    .wren_a   (vram2_wr),
    .address_a(cpu_addr[9:0]),
    .data_a   (cpu_dout),
    .q_a      (vram2_cpu_dout),

    .clock_b  (clk_master),
    .enable_b (1'b1),
    .wren_b   (1'b0),
    .address_b(vram2_vid_addr),
    .data_b   (8'd0),
    .q_b      (vram2_vid_dout)
);

// ---------------------------------------------------------------------------
// Video RAM 1 (background tilemap) - 1KB at $0800-$0BFF
// ---------------------------------------------------------------------------
wire vram1_cs = (cpu_addr[15:10] == 6'b000010);
wire [7:0] vram1_cpu_dout;
wire vram1_wr = vram1_cs & ~cpu_rw_n;

wire [9:0] vram1_vid_addr;
wire [7:0] vram1_vid_dout;

dpram #(.address_width(10)) vram1(
    .clock_a  (clk_master),
    .enable_a (cpu_clken),
    .wren_a   (vram1_wr),
    .address_a(cpu_addr[9:0]),
    .data_a   (cpu_dout),
    .q_a      (vram1_cpu_dout),

    .clock_b  (clk_master),
    .enable_b (1'b1),
    .wren_b   (1'b0),
    .address_b(vram1_vid_addr),
    .data_b   (8'd0),
    .q_b      (vram1_vid_dout)
);

// ---------------------------------------------------------------------------
// Color RAM - 1KB at $0C00-$0FFF
// ---------------------------------------------------------------------------
wire colorram_cs = (cpu_addr[15:10] == 6'b000011);
wire [7:0] colorram_cpu_dout;
wire colorram_wr = colorram_cs & ~cpu_rw_n;

wire [9:0] colorram_vid_addr;
wire [7:0] colorram_vid_dout;

dpram #(.address_width(10)) color_ram_inst(
    .clock_a  (clk_master),
    .enable_a (cpu_clken),
    .wren_a   (colorram_wr),
    .address_a(cpu_addr[9:0]),
    .data_a   (cpu_dout),
    .q_a      (colorram_cpu_dout),

    .clock_b  (clk_master),
    .enable_b (1'b1),
    .wren_b   (1'b0),
    .address_b(colorram_vid_addr),
    .data_b   (8'd0),
    .q_b      (colorram_vid_dout)
);

// ---------------------------------------------------------------------------
// Character Generator RAM - 4KB at $1000-$1FFF
// ---------------------------------------------------------------------------
wire charram_cs = (cpu_addr[15:12] == 4'b0001);
wire [7:0] charram_cpu_dout;
wire charram_wr = charram_cs & ~cpu_rw_n;

wire [11:0] charram_vid_addr;
wire [7:0]  charram_vid_dout;

dpram #(.address_width(12)) char_ram(
    .clock_a  (clk_master),
    .enable_a (cpu_clken),
    .wren_a   (charram_wr),
    .address_a(cpu_addr[11:0]),
    .data_a   (cpu_dout),
    .q_a      (charram_cpu_dout),

    .clock_b  (clk_master),
    .enable_b (1'b1),
    .wren_b   (1'b0),
    .address_b(charram_vid_addr),
    .data_b   (8'd0),
    .q_b      (charram_vid_dout)
);

// GFX ROM - always split at 4KB boundary in download space
// MRA must pad plane 0 to 4KB before plane 1 data
wire dn_gfx_p0 = dn_gfx1 & (dn_addr[12] == 1'b0);   // $10000-$10FFF
wire dn_gfx_p1 = dn_gfx1 & (dn_addr[12] == 1'b1);   // $11000-$11FFF

wire [11:0] bg_pixel_addr = {bg_tile_code[8:0], tile_line};
wire [7:0] bg_p0_dout, bg_p1_dout;

dpram #(.address_width(12)) gfx_p0(
    .clock_a  (clk_master),
    .enable_a (1'b1),
    .wren_a   (dn_wr & dn_gfx_p0),
    .address_a(dn_addr[11:0]),
    .data_a   (dn_data),
    .q_a      (),
    .clock_b  (clk_master),
    .enable_b (1'b1),
    .wren_b   (1'b0),
    .address_b(bg_pixel_addr),
    .data_b   (8'd0),
    .q_b      (bg_p0_dout)
);

dpram #(.address_width(12)) gfx_p1(
    .clock_a  (clk_master),
    .enable_a (1'b1),
    .wren_a   (dn_wr & dn_gfx_p1),
    .address_a(dn_addr[11:0]),
    .data_a   (dn_data),
    .q_a      (),
    .clock_b  (clk_master),
    .enable_b (1'b1),
    .wren_b   (1'b0),
    .address_b(bg_pixel_addr),
    .data_b   (8'd0),
    .q_b      (bg_p1_dout)
);

// ---------------------------------------------------------------------------
// Color PROMs - 64 bytes (2x 32-byte PROMs)
// ---------------------------------------------------------------------------
wire [7:0] prom_dout;
wire [5:0] prom_addr;

dpram #(.address_width(6)) color_proms(
    .clock_a  (clk_master),
    .enable_a (1'b1),
    .wren_a   (dn_wr & dn_proms),
    .address_a(dn_addr[5:0]),
    .data_a   (dn_data),
    .q_a      (),

    .clock_b  (clk_master),
    .enable_b (1'b1),
    .wren_b   (1'b0),
    .address_b(prom_addr),
    .data_b   (8'd0),
    .q_b      (prom_dout)
);

// ============================================================
// MC6845 CRTC
// ============================================================

wire crtc_cs;
assign crtc_cs =
    (game_id == GID_FANTASY || game_id == GID_NIBBLER) ? (cpu_addr[15:1] == 15'h1000) : // $2000-$2001
    (game_id == GID_PBALLOON) ? (cpu_addr[15:1] == 15'h5800) :                          // $B000-$B001
    (cpu_addr[15:1] == 15'h1800);                                                       // $3000-$3001 (default)

wire crtc_wr = crtc_cs & ~cpu_rw_n;

wire        crtc_hsync;
wire        crtc_vsync;
wire        crtc_hblank;
wire        crtc_vblank;
wire        crtc_de;
wire [13:0] crtc_ma;
wire [4:0]  crtc_ra;
wire [7:0]  crtc_dout;

mc6845 crtc(
    .CLOCK  (clk_master),
    .CLKEN  (crtc_clken),
    .nRESET (~cpu_reset),

    .ENABLE (crtc_cs & cpu_clken),
    .R_nW   (cpu_rw_n),
    .RS     (cpu_addr[0]),
    .DI     (cpu_dout),
    .DO     (crtc_dout),

    .VSYNC  (crtc_vsync),
    .HSYNC  (crtc_hsync),
    .VBLANK (crtc_vblank),
    .HBLANK (crtc_hblank),
    .DE     (crtc_de),
    .CURSOR (),
    .LPSTB  (1'b0),

    .MA     (crtc_ma),
    .RA     (crtc_ra)
);

wire [4:0] tile_col  = crtc_ma[4:0];
wire [4:0] tile_row  = crtc_ma[9:5];
wire [2:0] tile_line = crtc_ra[2:0];
wire [9:0] tile_addr = crtc_ma[9:0];

assign vram2_vid_addr    = tile_addr;
assign vram1_vid_addr    = tile_addr;
assign colorram_vid_addr = tile_addr;

// ============================================================
// I/O Write Decode
// ============================================================

// Common I/O write signals
wire io_wr = ~cpu_rw_n & cpu_clken;  // CPU is writing

// --- Vanguard I/O writes ($3xxx) ---
wire vg_sound_wr   = io_wr & (cpu_addr[15:8] == 8'h31) & (cpu_addr[1:0] != 2'b11);  // $3100-$3102
wire vg_flip_wr    = io_wr & (cpu_addr[15:0] == 16'h3103);
wire vg_scrollx_wr = io_wr & (cpu_addr[15:8] == 8'h32);  // $3200
wire vg_scrolly_wr = io_wr & (cpu_addr[15:8] == 8'h33);  // $3300
wire vg_speech_wr  = io_wr & (cpu_addr[15:8] == 8'h34);  // $3400

// --- Fantasy I/O writes ($2xxx) ---
wire fy_sound_wr   = io_wr & (cpu_addr[15:8] == 8'h21) & (cpu_addr[1:0] != 2'b11);
wire fy_flip_wr    = io_wr & (cpu_addr[15:0] == 16'h2103);
wire fy_scrollx_wr = io_wr & (cpu_addr[15:8] == 8'h22);
wire fy_scrolly_wr = io_wr & (cpu_addr[15:8] == 8'h23);
wire fy_speech_wr  = io_wr & (cpu_addr[15:8] == 8'h24);

// --- PBalloon I/O writes ($Bxxx) ---
wire pb_sound_wr   = io_wr & (cpu_addr[15:8] == 8'hB1) & (cpu_addr[1:0] != 2'b11);
wire pb_flip_wr    = io_wr & (cpu_addr[15:0] == 16'hB103);
wire pb_scrollx_wr = io_wr & (cpu_addr[15:8] == 8'hB2);
wire pb_scrolly_wr = io_wr & (cpu_addr[15:8] == 8'hB3);

// --- Sasuke/SatanSat I/O writes ($Bxxx, different layout) ---
wire ss_sound_wr   = io_wr & (cpu_addr[15:8] == 8'hB0) & (cpu_addr[0] != 1'b1 | cpu_addr[1] != 1'b1);
wire ss_b002_wr    = io_wr & (cpu_addr[15:0] == 16'hB002);
wire ss_bkcolor_wr = io_wr & (cpu_addr[15:0] == 16'hB003);

// Multiplexed write signals based on game_id
wire flip_wr = (game_id == GID_VANGUARD)  ? vg_flip_wr :
               (game_id == GID_FANTASY)   ? fy_flip_wr :
               (game_id == GID_NIBBLER)   ? fy_flip_wr :
               (game_id == GID_PBALLOON)  ? pb_flip_wr :
               1'b0;  // sasuke/satansat handled separately

wire scrollx_wr = (game_id == GID_VANGUARD)  ? vg_scrollx_wr :
                  (game_id == GID_FANTASY)   ? fy_scrollx_wr :
                  (game_id == GID_NIBBLER)   ? fy_scrollx_wr :
                  (game_id == GID_PBALLOON)  ? pb_scrollx_wr :
                  1'b0;

wire scrolly_wr = (game_id == GID_VANGUARD)  ? vg_scrolly_wr :
                  (game_id == GID_FANTASY)   ? fy_scrolly_wr :
                  (game_id == GID_NIBBLER)   ? fy_scrolly_wr :
                  (game_id == GID_PBALLOON)  ? pb_scrolly_wr :
                  1'b0;

// ---------------------------------------------------------------------------
// VBlank IRQ generation
// ---------------------------------------------------------------------------
reg irq_mask;   // only meaningful for sasuke/satansat

reg vblank_prev;
always @(posedge clk_master or posedge reset)
    if (reset)
        vblank_prev <= 1'b0;
    else
        vblank_prev <= crtc_vblank;

wire vblank_rising = crtc_vblank & ~vblank_prev;

reg cpu_irq;
always @(posedge clk_master or posedge reset)
    if (reset)
        cpu_irq <= 1'b0;
    else if (vblank_rising)
        cpu_irq <= (~is_slow_cpu || irq_mask) ? 1'b1 : 1'b0;
    else if (~crtc_vblank)
        cpu_irq <= 1'b0;

wire cpu_irq_n = ~cpu_irq;

// ============================================================
// Video Control Registers
// ============================================================
reg [2:0] backcolor;
reg       charbank;
reg       flip;
reg [7:0] scroll_x;
reg [7:0] scroll_y;

always @(posedge clk_master or posedge reset)
    if (reset) begin
        backcolor <= 3'd0;
        charbank  <= 1'b0;
        flip      <= 1'b0;
        scroll_x  <= 8'd0;
        scroll_y  <= 8'd0;
        irq_mask  <= 1'b0;
    end else begin
        // flipscreen_w (vanguard/fantasy/pballoon/nibbler)
        // bit 7 = flip screen, bit 3 = charbank (inverted), bits 2:0 = backcolor
        if (flip_wr) begin
            flip      <= cpu_dout[7];
            charbank  <= ~cpu_dout[3];
            backcolor <= cpu_dout[2:0];
        end

        // satansat_b002_w (sasuke/satansat only)
        // bit 0 = flip, bit 1 = irq_mask
        if (ss_b002_wr) begin
            flip     <= cpu_dout[0];
            irq_mask <= cpu_dout[1];
        end

        // satansat_backcolor_w (sasuke/satansat only)
        // bits 1:0 = backcolor
        if (ss_bkcolor_wr) begin
            backcolor <= {1'b0, cpu_dout[1:0]};
        end

        // Scroll registers
        if (scrollx_wr) scroll_x <= cpu_dout;
        if (scrolly_wr) scroll_y <= cpu_dout;
    end

assign flip_screen = flip;

// ============================================================
// I/O Read Decode
// ============================================================

wire in0_cs, in1_cs, dsw_cs, in2_cs;

assign in0_cs =
    (game_id <= GID_SATANSAT)  ? (cpu_addr == 16'hB004) :
    (game_id == GID_VANGUARD)  ? (cpu_addr == 16'h3104) :
    (game_id == GID_PBALLOON)  ? (cpu_addr == 16'hB104) :
    (cpu_addr == 16'h2104);  // fantasy/nibbler

assign in1_cs =
    (game_id <= GID_SATANSAT)  ? (cpu_addr == 16'hB005) :
    (game_id == GID_VANGUARD)  ? (cpu_addr == 16'h3105) :
    (game_id == GID_PBALLOON)  ? (cpu_addr == 16'hB105) :
    (cpu_addr == 16'h2105);

assign dsw_cs =
    (game_id <= GID_SATANSAT)  ? (cpu_addr == 16'hB006) :
    (game_id == GID_VANGUARD)  ? (cpu_addr == 16'h3106) :
    (game_id == GID_PBALLOON)  ? (cpu_addr == 16'hB106) :
    (cpu_addr == 16'h2106);

assign in2_cs =
    (game_id <= GID_SATANSAT)  ? (cpu_addr == 16'hB007) :
    (game_id == GID_VANGUARD)  ? (cpu_addr == 16'h3107) :
    (game_id == GID_PBALLOON)  ? (cpu_addr == 16'hB107) :
    (cpu_addr == 16'h2107);

// ============================================================
// Pixel Rendering Pipeline - locked to CRTC character clock
// ============================================================

// pix_cnt counts 0-7 pixels within each character, reset on crtc_clken
reg [2:0] pix_cnt;
always @(posedge clk_master or posedge reset)
    if (reset)
        pix_cnt <= 3'd0;
    else if (crtc_clken)
        pix_cnt <= 3'd0;
    else
        pix_cnt <= pix_cnt + 3'd1;

// ce_pix: one pulse per pixel = master clock / 2
assign ce_pix = clk_div[0];

wire [8:0] bg_tile_code = {charbank, vram1_vid_dout};

wire [2:0] bg_color = (game_id <= GID_SATANSAT) ?
    (colorram_vid_dout[3:2]) :
    (colorram_vid_dout[5:3]);

wire [7:0] fg_tile_code = vram2_vid_dout;
wire [2:0] fg_color = (game_id <= GID_SATANSAT) ?
    (colorram_vid_dout[1:0]) :
    (colorram_vid_dout[2:0]);

reg [7:0] bg_p0_latch, bg_p1_latch;
reg [7:0] fg_p0_latch, fg_p1_latch;
reg [2:0] bg_color_latch, fg_color_latch;

reg charram_plane_sel;
reg [7:0] fg_p0_raw, fg_p1_raw;

always @(posedge clk_master or posedge reset)
    if (reset)
        charram_plane_sel <= 1'b0;
    else if (crtc_clken)
        charram_plane_sel <= ~charram_plane_sel;

assign charram_vid_addr = {charram_plane_sel, fg_tile_code, tile_line};

always @(posedge clk_master)
    if (charram_plane_sel)
        fg_p0_raw <= charram_vid_dout;
    else
        fg_p1_raw <= charram_vid_dout;

// Latch tile data one clock after crtc_clken (dpram needs 1 cycle to respond to new MA)
reg crtc_clken_d;
always @(posedge clk_master) crtc_clken_d <= crtc_clken;

always @(posedge clk_master) begin
    if (crtc_clken_d) begin
        bg_p0_latch    <= bg_p0_dout;
        bg_p1_latch    <= bg_p1_dout;
        fg_p0_latch    <= fg_p0_raw;
        fg_p1_latch    <= fg_p1_raw;
        bg_color_latch <= bg_color;
        fg_color_latch <= fg_color;
    end else begin
        bg_p0_latch <= {bg_p0_latch[6:0], 1'b0};
        bg_p1_latch <= {bg_p1_latch[6:0], 1'b0};
        fg_p0_latch <= {fg_p0_latch[6:0], 1'b0};
        fg_p1_latch <= {fg_p1_latch[6:0], 1'b0};
    end
end

// Sasuke swaps bitplane order in GFX ROM
wire sasuke_swap = (game_id == GID_SASUKE);
wire [1:0] bg_pixel_raw = {bg_p1_latch[7], bg_p0_latch[7]};
wire [1:0] bg_pixel = sasuke_swap ? {bg_pixel_raw[0], bg_pixel_raw[1]} : bg_pixel_raw;

wire [1:0] fg_pixel = {fg_p1_latch[7], fg_p0_latch[7]};

wire fg_transparent = (fg_pixel == 2'b00);

wire [1:0] final_pixel = fg_transparent ? bg_pixel : fg_pixel;
wire [2:0] final_color = fg_transparent ? bg_color_latch : fg_color_latch;
wire       final_is_bg = fg_transparent;

// ============================================================
// Palette from PROMs
// ============================================================

wire [4:0] fg_prom_addr = {fg_color_latch, fg_pixel};
wire [4:0] bg_prom_addr_raw = {bg_color_latch, bg_pixel};
wire [4:0] bg_prom_addr = (bg_pixel == 2'b00) ?
    {backcolor, 2'b00} : bg_prom_addr_raw;

// Sasuke/SatanSat palette addressing is different
// FG: prom[4*(pixel) + color] instead of prom[color*4 + pixel]
// BG: same but offset by $10, pixel 0 = backcolor
wire [4:0] ss_fg_prom_addr = {fg_pixel, fg_color_latch[1:0]};
wire [4:0] ss_bg_prom_addr = (bg_pixel == 2'b00) ?
    {3'b100, backcolor[1:0]} :
    {1'b1, bg_pixel, bg_color_latch[1:0]};  // $10 + 4*pixel + color

// Select palette addressing based on game
assign prom_addr = (game_id <= GID_SATANSAT) ?
    (final_is_bg ? {1'b0, ss_bg_prom_addr} : {1'b0, ss_fg_prom_addr}) :
    (final_is_bg ? {1'b1, bg_prom_addr} : {1'b0, fg_prom_addr});

reg display_active;
always @(posedge clk_master)
    display_active <= crtc_de & ~crtc_hblank & ~crtc_vblank;

wire [7:0] red_out   = {prom_dout[2], prom_dout[1], prom_dout[0],
                         prom_dout[2], prom_dout[1], prom_dout[0],
                         prom_dout[2], prom_dout[1]};
wire [7:0] green_out = {prom_dout[5], prom_dout[4], prom_dout[3],
                         prom_dout[5], prom_dout[4], prom_dout[3],
                         prom_dout[5], prom_dout[4]};
wire [7:0] blue_out  = {prom_dout[7], prom_dout[6], 1'b0,
                         prom_dout[7], prom_dout[6], 1'b0,
                         prom_dout[7], prom_dout[6]};

// ---------------------------------------------------------------------------
// CPU read data mux
// ---------------------------------------------------------------------------
assign cpu_din =
    ram_cs      ? ram_dout :
    vram2_cs    ? vram2_cpu_dout :
    vram1_cs    ? vram1_cpu_dout :
    colorram_cs ? colorram_cpu_dout :
    charram_cs  ? charram_cpu_dout :
    crtc_cs     ? crtc_dout :
    in0_cs      ? in0 :
    in1_cs      ? in1 :
    dsw_cs      ? dsw :
    in2_cs      ? in2 :
    rom_dout;

// ---------------------------------------------------------------------------
// Video sync/blank outputs from CRTC
// ---------------------------------------------------------------------------
assign hsync  = crtc_hsync;
assign vsync  = crtc_vsync;
assign hblank = crtc_hblank;
assign vblank = crtc_vblank;

// ---------------------------------------------------------------------------
// RGB pixel output
// ---------------------------------------------------------------------------
// DEBUG: show raw GFX ROM bitplane data
assign rgb_r = display_active ? bg_p0_latch : 8'd0;
assign rgb_g = display_active ? bg_p1_latch : 8'd0;
assign rgb_b = display_active ? fg_p0_latch : 8'd0;

// ---------------------------------------------------------------------------
// NMI from coin insertion
// ---------------------------------------------------------------------------
// NMI on coin insertion - edge triggered one-shot
reg coin_prev;
reg cpu_nmi;
always @(posedge clk_master or posedge reset)
    if (reset) begin
        coin_prev <= 1'b0;
        cpu_nmi   <= 1'b0;
    end else begin
        coin_prev <= in2[1] | in2[0];
        // pulse NMI for one cpu_clken on rising edge of coin
        if ((in2[1] | in2[0]) & ~coin_prev)
            cpu_nmi <= 1'b1;
        else if (cpu_clken)
            cpu_nmi <= 1'b0;
    end
assign cpu_nmi_n = ~cpu_nmi;

// ---------------------------------------------------------------------------
// Remaining stub outputs
// ---------------------------------------------------------------------------
assign audio = 16'd0;

// ============================================================
// DIAGNOSTIC: game_id and CRTC write visibility
// ============================================================
assign dbg_game_id = game_id;

// Latch: has crtc_cs ever been asserted during a CPU write?
reg crtc_ever_hit;
always @(posedge clk_master or posedge reset)
    if (reset)
        crtc_ever_hit <= 1'b0;
    else if (crtc_cs & ~cpu_rw_n & cpu_clken)
        crtc_ever_hit <= 1'b1;
assign dbg_crtc_hit = crtc_ever_hit;

// Latch: has the CPU ever accessed an address in the $2000-$2FFF range?
reg cpu_touched_2xxx;
always @(posedge clk_master or posedge reset)
    if (reset)
        cpu_touched_2xxx <= 1'b0;
    else if (cpu_clken & (cpu_addr[15:12] == 4'h2))
        cpu_touched_2xxx <= 1'b1;
assign dbg_cpu_active = cpu_touched_2xxx;

endmodule