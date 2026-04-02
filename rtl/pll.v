`timescale 1 ps / 1 ps
module pll (
    input  wire  refclk,
    input  wire  rst,
    output wire  outclk_0,    // ~45.158 MHz (video clock, 4x master)
    output wire  outclk_1,    // ~22.579 MHz (2x master)
    output wire  outclk_2,    // ~11.289 MHz (master clock)
    output wire  locked
);

    pll_0002 pll_inst (
        .refclk            (refclk),
        .rst               (rst),
        .outclk_0          (outclk_0),
        .outclk_1          (outclk_1),
        .outclk_2          (outclk_2),
        .locked            (locked),
        .reconfig_to_pll   (64'd0),
        .reconfig_from_pll ()
    );

endmodule
