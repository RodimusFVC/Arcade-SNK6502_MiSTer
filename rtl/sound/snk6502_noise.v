// snk6502_noise.v
// One-shot noise burst for Fantasy/Nibbler/Vanguard bomb/explosion sound
// Based on SN76477 config in MAME snk6502_a.cpp:
//   mixer=noise only, envelope=one-shot, fixed RC decay ~26ms
// Triggered on rising edge of 'trigger' input

module snk6502_noise (
    input  wire        clk,       // 11.289 MHz master clock
    input  wire        reset,
    input  wire        trigger,   // rising edge fires one-shot
    output reg  signed [15:0] audio_out
);

    // 26ms one-shot decay @ 11.289MHz = 293,514 clocks
    localparam DECAY_LEN = 19'd293514;

    reg [18:0] decay_cnt;
    reg        trig_prev;

    wire trig_edge = trigger & ~trig_prev;

    // 16-bit Galois LFSR noise generator
    // Taps: 16,15,13,4 — maximal length sequence
    reg [15:0] lfsr;
    wire lfsr_feedback = lfsr[0];

    always @(posedge clk) begin
        if (reset)
            lfsr <= 16'hACE1;
        else
            lfsr <= {lfsr_feedback, lfsr[15:1]} ^
                    (lfsr_feedback ? 16'hB400 : 16'h0000);
    end

    // 4-bit envelope: top 4 bits of decay counter, 15..0 as it runs down
    wire [3:0] envelope = decay_cnt[18:15];

    // Noise signal: shift LFSR up to use full 16-bit range
    wire signed [15:0] noise_sig = {lfsr[11:0], 4'b0};

    // One-shot state machine + output
    always @(posedge clk) begin
        if (reset) begin
            decay_cnt <= 0;
            trig_prev <= 0;
            audio_out <= 0;
        end else begin
            trig_prev <= trigger;

            if (trig_edge)
                decay_cnt <= DECAY_LEN;
            else if (|decay_cnt)
                decay_cnt <= decay_cnt - 1'd1;

            if (|decay_cnt)
                audio_out <= $signed(noise_sig) * $signed({1'b0, envelope}) >>> 4;
            else
                audio_out <= 0;
        end
    end

endmodule