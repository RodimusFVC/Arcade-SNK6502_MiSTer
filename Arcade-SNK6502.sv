//============================================================================
//  Arcade: SNK6502 (Vanguard, Sasuke vs Commander, Fantasy, etc.)
//
//  Port to MiSTer
//  Copyright (C) 2024
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign FB_FORCE_BLANK = '0;

assign VGA_F1 = '0;
assign VGA_SCALER = '0;
assign VGA_DISABLE = '0;
assign HDMI_FREEZE = '0;
assign HDMI_BLACKOUT = '0;
assign HDMI_BOB_DEINT = '0;

assign AUDIO_MIX = '0;

assign LED_DISK = '0;
assign LED_POWER = '0;
// DIAGNOSTIC: LED_USER blinks if game_id==5. Steady on if CRTC was written.
// assign LED_USER = dbg_crtc_hit ? 1'b1 : dbg_cpu_active;
assign BUTTONS = '0;

wire [1:0] ar = status[20:19];

assign VIDEO_ARX = (!ar) ? (status[2] ? 8'd4 : 8'd3) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (status[2] ? 8'd3 : 8'd4) : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"SNK6502;;",
	"H0OJK,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"H0O2,Orientation,Vert,Horz;",
	"O35,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"OB,Vertical flip,Off,On;",
	"-;",
	"DIP;",
	"-;",
	"P1,Pause options;",
	"P1OP,Pause when OSD is open,On,Off;",
	"P1OQ,Dim video after 10s,On,Off;",
	"-;",
	"R0,Reset;",
	// Button 1..4 = ABXY (SNES face-button layout: A=right, B=down, X=up, Y=left).
	// For Vanguard, ABXY map directly onto fire-right/down/up/left.
	// For 1-button games (Pballoon/Fantasy), all four ABXY fire.
	"J1,Button 1,Button 2,Button 3,Button 4,Coin,Start 1P,Start 2P,Pause;",
	"jn,A,B,X,Y,Select,Start,R,L;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_vid;      // ~45 MHz video clock
wire clk_master;   // ~11.289 MHz game master clock
wire pll_locked;

pll pll
(
    .refclk(CLK_50M),
    .rst(0),
    .outclk_0(clk_vid),      // ~45 MHz
    .outclk_1(),              // ~22.5 MHz (unused for now)
    .outclk_2(clk_master),   // ~11.289 MHz
    .locked(pll_locked)
);

wire clk_sys = clk_vid;

///////////////////////////////////////////////////

wire [31:0] status;
wire  [1:0] buttons;
wire        forced_scandoubler;
wire        video_rotated;
wire        direct_video;

wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_din;

wire [15:0] joystick_0, joystick_1;
wire [15:0] joystick_r_analog_0;   // right analog stick: [15:8]=Y signed, [7:0]=X signed
wire [10:0] ps2_key;

wire [21:0] gamma_bus;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	.status_menumask({direct_video}),

	.forced_scandoubler(forced_scandoubler),
	.video_rotated(video_rotated),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_index(ioctl_index),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_r_analog_0(joystick_r_analog_0),
	.ps2_key(ps2_key)
);

assign ioctl_upload_req = 1'b0;
assign ioctl_din        = 8'd0;

// Game ID - loaded from .mra via ioctl_index 1
reg [3:0] game_id;
always @(posedge clk_sys)
	if (ioctl_wr && ioctl_index == 8'd1 && ioctl_addr == 25'd0)
		game_id <= ioctl_dout[3:0];

// PAUSE SYSTEM
wire        pause_cpu;
wire [8:0]  rgb_out;
pause #(3,3,3,24) pause (
	.*,
	.user_button(m_pause),
	.pause_request(1'b0),
	.options(~status[26:25]),
	.r(rgb_in[2:0]),
	.g(rgb_in[5:3]),
	.b(rgb_in[8:6])
);

///////////////////   CONTROLS   ////////////////////

// Game ID constants (must match rtl/snk6502.v)
localparam GID_SASUKE   = 4'd0;
localparam GID_SATANSAT = 4'd1;
localparam GID_VANGUARD = 4'd2;
localparam GID_FANTASY  = 4'd3;
localparam GID_PBALLOON = 4'd4;
localparam GID_NIBBLER  = 4'd5;

// ----- PS/2 Keyboard -----
reg btn_up       = 0;
reg btn_down     = 0;
reg btn_left     = 0;
reg btn_right    = 0;
reg btn_fire1    = 0;
reg btn_fire2    = 0;
reg btn_fire3    = 0;
reg btn_fire4    = 0;
reg btn_coin1    = 0;
reg btn_coin2    = 0;
reg btn_1p_start = 0;
reg btn_2p_start = 0;
reg btn_pause    = 0;

wire pressed = ~ps2_key[9];
wire [7:0] code = ps2_key[7:0];
always @(posedge clk_sys) begin
	reg old_state;
	old_state <= ps2_key[10];
	if (old_state != ps2_key[10]) begin
		case (code)
			'h16: btn_1p_start <= pressed; // 1
			'h1E: btn_2p_start <= pressed; // 2
			'h2E: btn_coin1    <= pressed; // 5
			'h36: btn_coin2    <= pressed; // 6
			'h4D: btn_pause    <= pressed; // P
			'h75: btn_up       <= pressed; // up
			'h72: btn_down     <= pressed; // down
			'h6B: btn_left     <= pressed; // left
			'h74: btn_right    <= pressed; // right
			'h14: btn_fire1    <= pressed; // L ctrl  = Button 1 (A)
			'h12: btn_fire2    <= pressed; // L shift = Button 2 (B)
			'h11: btn_fire3    <= pressed; // L alt   = Button 3 (X)
			'h29: btn_fire4    <= pressed; // space   = Button 4 (Y)
		endcase
	end
end

// ----- Right analog stick decode (Vanguard secondary fire) -----
// joystick_r_analog_0[7:0]  = X axis (signed), positive = right
// joystick_r_analog_0[15:8] = Y axis (signed), positive = down
// Threshold of ±64/127 (~half deflection) — same as Qix.
wire signed [7:0] rstick_x = joystick_r_analog_0[7:0];
wire signed [7:0] rstick_y = joystick_r_analog_0[15:8];
wire r_fire_right = (rstick_x >  8'sd64);
wire r_fire_left  = (rstick_x < -8'sd64);
wire r_fire_down  = (rstick_y >  8'sd64);
wire r_fire_up    = (rstick_y < -8'sd64);

// ----- Sasuke / SatanSat free-running counter -----
// MAME (snk6502.cpp): 8-bit counter += 0x10 at 1.4 MHz; sasuke_count_r() = counter >> 4.
// Net effect: 4-bit counter at ~1.4 MHz feeding IN2[7:4]. Used by game as RNG.
// clk_master ≈ 11.289 MHz; /8 ≈ 1.411 MHz.
// Counter lives in clk_master domain — IN ports are sampled by CPU also in clk_master,
// so a single-bit transition crossing the assign is benign for an RNG bit.
reg [2:0] sasuke_div   = 3'd0;
reg [3:0] sasuke_count = 4'd0;
always @(posedge clk_master) begin
	sasuke_div <= sasuke_div + 3'd1;
	if (sasuke_div == 3'd7)
		sasuke_count <= sasuke_count + 4'd1;
end

// ----- DPAD directions -----
wire m_up1    = btn_up    | joystick_0[3];
wire m_down1  = btn_down  | joystick_0[2];
wire m_left1  = btn_left  | joystick_0[1];
wire m_right1 = btn_right | joystick_0[0];

wire m_up2    = joystick_1[3];
wire m_down2  = joystick_1[2];
wire m_left2  = joystick_1[1];
wire m_right2 = joystick_1[0];

// ----- Face buttons (ABXY) -----
// jn: A=joystick[4], B=joystick[5], X=joystick[6], Y=joystick[7]
//
// Vanguard convention (matches each button's physical position on the pad):
//   A = fire RIGHT
//   B = fire DOWN
//   X = fire UP
//   Y = fire LEFT
wire m_btn1_p1 = btn_fire1 | joystick_0[4];   // A
wire m_btn2_p1 = btn_fire2 | joystick_0[5];   // B
wire m_btn3_p1 = btn_fire3 | joystick_0[6];   // X
wire m_btn4_p1 = btn_fire4 | joystick_0[7];   // Y

wire m_btn1_p2 = joystick_1[4];
wire m_btn2_p2 = joystick_1[5];
wire m_btn3_p2 = joystick_1[6];
wire m_btn4_p2 = joystick_1[7];

// Vanguard fire bits = ABXY OR'd with right analog stick
wire m_fire_right_p1 = m_btn1_p1 | r_fire_right;  // A   or stick right
wire m_fire_down_p1  = m_btn2_p1 | r_fire_down;   // B   or stick down
wire m_fire_up_p1    = m_btn3_p1 | r_fire_up;     // X   or stick up
wire m_fire_left_p1  = m_btn4_p1 | r_fire_left;   // Y   or stick left

wire m_fire_right_p2 = m_btn1_p2;
wire m_fire_down_p2  = m_btn2_p2;
wire m_fire_up_p2    = m_btn3_p2;
wire m_fire_left_p2  = m_btn4_p2;

// ----- Coin / Start / Pause -----
wire m_coin1  = btn_coin1    | joystick_0[8];   // Select = Coin
wire m_coin2  = btn_coin2    | joystick_1[8];
wire m_start1 = btn_1p_start | joystick_0[9];   // Start  = Start 1P
wire m_start2 = btn_2p_start | joystick_1[9];   // R      = Start 2P
wire m_pause  = btn_pause    | joystick_0[11];  // L      = Pause

// =========================================================================
// Per-game IN0 / IN1 / IN2 construction (active high — matches MAME)
// Bit ordering reminder: {b7, b6, b5, b4, b3, b2, b1, b0}
// =========================================================================

// --- Sasuke (game_id=0) ---
//  IN0 b7=START2 b6=START1 b5..3=cocktail b2=BTN1 b1=R(2W) b0=L(2W)
//  IN1 b7=music0_playing(NI) b1..0=unused
//  IN2 b7..4=sasuke_count_r(NI) b3..1=NC b0=COIN1
wire [7:0] in0_sasuke   = {m_start2, m_start1, 3'b000, m_btn1_p1, m_right1, m_left1};
wire [7:0] in1_sasuke   = {music0_playing, 7'b0000000};
wire [7:0] in2_sasuke   = {sasuke_count, 3'b000, m_coin1};

// --- SatanSat / Zarzon (game_id=1) ---
//  IN0 b7=BTN2_cock b6=BTN2 b5..3=cocktail b2=BTN1 b1=R(2W) b0=L(2W)
//  IN1 b7=music0_playing(NI) b6..2=NC b1=START2 b0=START1
//  IN2 b7..4=sasuke_count_r(NI) b3..1=NC b0=COIN1
wire [7:0] in0_satansat = {1'b0, m_btn2_p1, 3'b000, m_btn1_p1, m_right1, m_left1};
wire [7:0] in1_satansat = {music0_playing, 5'b00000, m_start2, m_start1};
wire [7:0] in2_satansat = {sasuke_count, 3'b000, m_coin1};

// --- Vanguard (game_id=2) ---
//  IN0 b7=L  b6=R  b5=U  b4=D  b3=BTN1(fireL) b2=BTN2(fireR) b1=BTN4(fireU) b0=BTN3(fireD)
//  IN1 same layout for P2 cocktail
//  IN2 b7=START1 b6=START2 b5=NC b4=music0_playing(NI) b3..2=NC b1=COIN1 b0=COIN2
wire [7:0] in0_vanguard = {m_left1, m_right1, m_up1, m_down1,
                           m_fire_left_p1, m_fire_right_p1, m_fire_up_p1, m_fire_down_p1};
wire [7:0] in1_vanguard = {m_left2, m_right2, m_up2, m_down2,
                           m_fire_left_p2, m_fire_right_p2, m_fire_up_p2, m_fire_down_p2};
wire [7:0] in2_vanguard = {m_start1, m_start2, 1'b0, music0_playing, 2'b00, m_coin1, m_coin2};

// --- Fantasy (game_id=3) ---
//  IN0 b7=L b6=R b5=U b4=D (8W); MAME has b3..0=UNKNOWN.
//  Real hw has a fire button — map it to b3 like pballoon (any ABXY OR'd).
//  IN2 same as Vanguard but with b4=NC (no music0 read)
wire [7:0] in0_fantasy  = {m_left1, m_right1, m_up1, m_down1, m_btn1_p1, 3'b000};
wire [7:0] in1_fantasy  = {m_left2, m_right2, m_up2, m_down2, m_btn1_p2, 3'b000};
wire [7:0] in2_fantasy  = {m_start1, m_start2, 4'b0000, m_coin1, m_coin2};

// --- Pioneer Balloon (game_id=4) ---
//  IN0 b7=L b6=R b5=U b4=D b3=BTN1 b2..0=UNKNOWN
//  IN2 same as fantasy
wire [7:0] in0_pballoon = {m_left1, m_right1, m_up1, m_down1, m_btn1_p1, 3'b000};
wire [7:0] in1_pballoon = {m_left2, m_right2, m_up2, m_down2, m_btn1_p2, 3'b000};
wire [7:0] in2_pballoon = {m_start1, m_start2, 4'b0000, m_coin1, m_coin2};

// --- Nibbler (game_id=5) ---
// Real Nibbler cabinet has NO buttons — IN0/IN1 bits 0-3 are unconnected.
// MAME maps debug service inputs (slow-down, pause, end-game) onto those bits
// for testing, but the ROM treats any high level on those bits as debug
// activity. Putting any button there causes weird in-game behaviour
// including disabling normal coin/credit handling.
wire [7:0] in0_nibbler  = {m_left1, m_right1, m_up1, m_down1, 4'b0000};
wire [7:0] in1_nibbler  = {m_left2, m_right2, m_up2, m_down2, 4'b0000};
wire [7:0] in2_nibbler  = {m_start1, m_start2, 4'b0000, m_coin1, m_coin2};

// --- Per-game mux ---
reg [7:0] snk_in0, snk_in1, snk_in2;
always @(*) begin
	case (game_id)
		GID_NIBBLER:  begin snk_in0 = in0_nibbler;  snk_in1 = in1_nibbler;  snk_in2 = in2_nibbler;  end
		GID_FANTASY:  begin snk_in0 = in0_fantasy;  snk_in1 = in1_fantasy;  snk_in2 = in2_fantasy;  end
		GID_PBALLOON: begin snk_in0 = in0_pballoon; snk_in1 = in1_pballoon; snk_in2 = in2_pballoon; end
		GID_VANGUARD: begin snk_in0 = in0_vanguard; snk_in1 = in1_vanguard; snk_in2 = in2_vanguard; end
		GID_SASUKE:   begin snk_in0 = in0_sasuke;   snk_in1 = in1_sasuke;   snk_in2 = in2_sasuke;   end
		GID_SATANSAT: begin snk_in0 = in0_satansat; snk_in1 = in1_satansat; snk_in2 = in2_satansat; end
		default:      begin snk_in0 = in0_nibbler;  snk_in1 = in1_nibbler;  snk_in2 = in2_nibbler;  end
	endcase
end

assign LED_USER = m_coin1;

// DSW: from DIP switch array
wire [7:0] snk_dsw = sw[0];

// DIPS
reg [7:0] sw[8];
always @(posedge clk_sys)
begin
	if (ioctl_wr && (ioctl_index==8'd254) && !ioctl_addr[24:3]) sw[ioctl_addr[2:0]] <= ioctl_dout;
end

// ROM download
wire rom_download = ioctl_download & (ioctl_index == 8'd0);
wire reset = (RESET | status[0] | buttons[1] | ioctl_download);

// Game core outputs
wire [7:0] core_r, core_g, core_b;
wire       core_hs, core_vs, core_hb, core_vb;
wire [15:0] core_audio;
wire        core_flip;
wire        ce_pix;
wire [3:0]  dbg_game_id;
wire        dbg_crtc_hit;
wire        dbg_cpu_active;
wire        music0_playing;   // MAME custom bit — high when sound ch0 is muted

snk6502 game_core(
	.clk_master (clk_master),
	.clk_sys    (clk_sys),
	.reset      (reset),
	.pause      (pause_cpu),

	.game_id    (game_id),

	.in0        (snk_in0),
	.in1        (snk_in1),
	.in2        (snk_in2),
	.dsw        (snk_dsw),

	.dn_addr    (ioctl_addr[16:0]),
	.dn_data    (ioctl_dout),
	.dn_wr      (ioctl_wr & rom_download),

	.rgb_r      (core_r),
	.rgb_g      (core_g),
	.rgb_b      (core_b),
	.hsync      (core_hs),
	.vsync      (core_vs),
	.hblank     (core_hb),
	.vblank     (core_vb),

	.audio      (core_audio),
	.flip_screen(core_flip),
	.ce_pix     (ce_pix),

	.music0_playing(music0_playing)
);

// DISPLAY
// Convert 8-bit RGB channels to 9-bit (3-3-3) for arcade_video
wire [8:0] rgb_in = {core_b[7:5], core_g[7:5], core_r[7:5]};

wire hblank = core_hb;
wire vblank = core_vb;
wire hs = core_hs;
wire vs = core_vs;

// ce_pix: sync rising edge from clk_master into clk_vid domain
reg ce_pix_r, ce_pix_rr;
always @(posedge clk_vid) begin ce_pix_r <= ce_pix; ce_pix_rr <= ce_pix_r; end
wire ce_pix_sync = ce_pix_r & ~ce_pix_rr;

wire no_rotate = status[2] | direct_video;
wire rotate_ccw = 0;
wire flip = status[11];

screen_rotate screen_rotate (.*);

arcade_video #(256,9,1) arcade_video
(
	.*,
    .clk_video(clk_vid),
	.RGB_in(rgb_out),
	.ce_pix    (ce_pix_sync),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hs),
	.VSync(vs),
	.fx(status[5:3])
);

assign CLK_VIDEO = clk_vid;
assign AUDIO_L = core_audio;
assign AUDIO_R = core_audio;
assign AUDIO_S = 1'b1;

endmodule
