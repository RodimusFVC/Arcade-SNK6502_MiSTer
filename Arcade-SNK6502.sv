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
assign LED_USER = dbg_crtc_hit ? 1'b1 : dbg_cpu_active;
assign BUTTONS = '0;

wire [1:0] ar = status[20:19];

assign VIDEO_ARX = (!ar) ? (status[2] ? 8'd16 : 8'd15) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (status[2] ? 8'd15 : 8'd16) : 12'd0;

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
	"J1,Fire Left,Fire Right,Fire Up,Fire Down,Start 1P,Start 2P,Coin,Pause;",
	"Jn,A,B,X,Y,Start,Select,R,L;",
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
	.joystick_1(joystick_1)
);

assign ioctl_upload_req = 1'b0;
assign ioctl_din        = 8'd0;

///////////////////   CONTROLS   ////////////////////

// Joystick mapping
// MiSTer joystick bits: 0=right, 1=left, 2=down, 3=up, 4+=buttons

// Player 1 directional inputs
wire m_up1    = joystick_0[3];
wire m_down1  = joystick_0[2];
wire m_left1  = joystick_0[1];
wire m_right1 = joystick_0[0];

// Player 2 directional inputs
wire m_up2    = joystick_1[3];
wire m_down2  = joystick_1[2];
wire m_left2  = joystick_1[1];
wire m_right2 = joystick_1[0];

// Buttons: mapped per Vanguard layout (4 fire directions)
wire m_fire_left1  = joystick_0[4];
wire m_fire_right1 = joystick_0[5];
wire m_fire_up1    = joystick_0[6];
wire m_fire_down1  = joystick_0[7];

wire m_fire_left2  = joystick_1[4];
wire m_fire_right2 = joystick_1[5];
wire m_fire_up2    = joystick_1[6];
wire m_fire_down2  = joystick_1[7];

wire m_start1 = joystick_0[8];
wire m_start2 = joystick_0[9];
wire m_coin1  = joystick_0[10];
wire m_coin2  = joystick_1[10];

wire m_pause  = joystick_0[11];

// Build SNK6502 input ports
// IN0: player 1 (active high per MAME)
// Vanguard: bits 7:4 = joystick L/R/U/D, bits 3:0 = fire D/U/R/L
wire [7:0] snk_in0 = {m_left1, m_right1, m_up1, m_down1,
                       m_fire_down1, m_fire_up1, m_fire_right1, m_fire_left1};

// IN1: player 2
wire [7:0] snk_in1 = {m_left2, m_right2, m_up2, m_down2,
                       m_fire_down2, m_fire_up2, m_fire_right2, m_fire_left2};

// IN2: coins, starts, misc
wire [7:0] snk_in2 = {m_start1, m_start2, 4'b0000, m_coin1, m_coin2};

// DSW: from DIP switch array
wire [7:0] snk_dsw = sw[0];

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

// DIPS
reg [7:0] sw[8];
always @(posedge clk_sys)
begin
	if (ioctl_wr && (ioctl_index==8'd254) && !ioctl_addr[24:3]) sw[ioctl_addr[2:0]] <= ioctl_dout;
end

// Game ID - loaded from .mra via ioctl_index 1
reg [3:0] game_id;
always @(posedge clk_sys)
	if (ioctl_wr && ioctl_index == 8'd1 && ioctl_addr == 25'd0)
		game_id <= ioctl_dout[3:0];

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

	.dbg_game_id  (dbg_game_id),
	.dbg_crtc_hit (dbg_crtc_hit),
	.dbg_cpu_active(dbg_cpu_active)
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
