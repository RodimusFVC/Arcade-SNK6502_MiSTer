module snk6502_snd (
    input  wire                 clk,          // 11.289 MHz master clock
    input  wire                 reset,
    input  wire        [7:0]    sound_port0,  // CPU write data for port 0
    input  wire        [7:0]    sound_port1,  // CPU write data for port 1
    input  wire        [7:0]    sound_port2,  // CPU write data for port 2
    input  wire        [7:0]    sound_port3,  // CPU write data for port 3 (new)
    input  wire                 wr0,          // one-cycle write strobe for port 0
    input  wire                 wr1,          // one-cycle write strobe for port 1
    input  wire                 wr2,          // one-cycle write strobe for port 2
    input  wire                 wr3,          // one-cycle write strobe for port 3 (new)
    input  wire        [7:0]    snd_rom_data, // data from external sound ROM (combinatorial or 1-cycle registered)
    output reg         [12:0]   snd_rom_addr, // address to sound ROM
    output reg  signed [15:0]   audio_out     // 16-bit signed PCM output (sum of 3 channels)
);

    //////////////////////////////////////////////////////////////////////////
    // References to MAME snk6502_a.cpp (fantasy/nibbler path)
    // - 3 independent tone channels
    // - Offset counter advances at music clock (~41 Hz)
    // - ROM lookup at (base + offset) yields period byte
    // - If period == 0xFF → channel silent
    // - sample_step derived from music_freq / (256 - period)
    // - Waveform table (16 entries, signed) updated by CPU via build_waveform
    // - Phase accumulator steps through waveform at sample_step rate
    // - Special square-wave handling for channel 2 (Fantasy/Nibbler)
    // - ROM bases (Nibbler/Fantasy): ch0=0x000, ch1=0x800, ch2=0x1000
    //////////////////////////////////////////////////////////////////////////

    localparam MUSIC_DIV   = 19'd273999; // master/≈274000 ≈ 41.2 Hz (matches fantasy 41.6 Hz closely)
    localparam FRAC_BITS   = 16;
    localparam FRAC_ONE    = 32'd65536;

    // Per-channel state
    reg [7:0]  ch_offset [0:2];
    reg [12:0] ch_base   [0:2];
    reg [7:0]  ch_mask   [0:2];
    reg        ch_mute   [0:2];
    reg signed [15:0] ch_form [0:2][0:15];
    reg [31:0] ch_phase      [0:2];
    reg [31:0] ch_phase_step [0:2];  // pre-scaled increment per master clock (fixed-point)

    // ROM fetch sequencer (round-robin read of 3 channels after each music tick)
    reg [1:0] rom_sel;
    reg [1:0] rom_latch_sel;
    reg [7:0] ch_romdata [0:2];

    // Music clock divider
    reg [18:0] music_cnt;
    wire music_tick = (music_cnt == MUSIC_DIV);

    // Waveform rebuild control (new state-machine registers)
    reg       wf_wr;
    reg [7:0] wf_data;
    reg [4:0] wf_state;   // 0-31: first 16 = ch0, next 16 = ch1
    reg       wf_busy;
    reg [3:0] ch0_wf_mask, ch1_wf_mask;

    // Moved declarations for always-block variables (required for synthesis)
    reg [7:0] idx;
    reg signed [31:0] sum;
    reg [31:0] cur_pos;
    reg [3:0]  prev_idx, cur_idx;
    reg signed [15:0] prev_val, cur_val;
    reg [31:0] frac;
    reg signed [31:0] interp;

    integer i;
    integer j;

    reg [3:0] wf_m;
    reg [3:0] wf_j;
    reg [4:0] wf_bit0, wf_bit1, wf_bit2, wf_bit3;
    reg [4:0] wf_base_val, wf_data_val;

    wire [3:0] ch0_mask_calc = ((wf_data & 8'h09) | ((wf_data & 8'h02) << 1) | ((wf_data & 8'h04) >> 1)) & 8'h0F;

    // Phase increment LUT
    // Computed as round(1048576 * 65536 / (526 * d)) where d = 256 - period
    // (derived from music_freq = master/263 → tone_freq = music_freq/(2*d) → phase_inc = 2^20/(526*d))
    // Matches MAME pitch exactly without floating-point or runtime division.
    reg [31:0] phase_inc_lut [0:255];
    initial begin
        phase_inc_lut[  0] = 32'd130645393; phase_inc_lut[  1] = 32'd65322697; phase_inc_lut[  2] = 32'd43548464;
        phase_inc_lut[  3] = 32'd32661348; phase_inc_lut[  4] = 32'd26129079; phase_inc_lut[  5] = 32'd21774232;
        phase_inc_lut[  6] = 32'd18663628; phase_inc_lut[  7] = 32'd16330674; phase_inc_lut[  8] = 32'd14516155;
        phase_inc_lut[  9] = 32'd13064539; phase_inc_lut[ 10] = 32'd11876854; phase_inc_lut[ 11] = 32'd10887116;
        phase_inc_lut[ 12] = 32'd10049646; phase_inc_lut[ 13] = 32'd9331814;  phase_inc_lut[ 14] = 32'd8709693;
        phase_inc_lut[ 15] = 32'd8165337;  phase_inc_lut[ 16] = 32'd7685023;  phase_inc_lut[ 17] = 32'd7258077;
        phase_inc_lut[ 18] = 32'd6876073;  phase_inc_lut[ 19] = 32'd6532270;  phase_inc_lut[ 20] = 32'd6221209;
        phase_inc_lut[ 21] = 32'd5938427;  phase_inc_lut[ 22] = 32'd5680234;  phase_inc_lut[ 23] = 32'd5443558;
        phase_inc_lut[ 24] = 32'd5225816;  phase_inc_lut[ 25] = 32'd5024823;  phase_inc_lut[ 26] = 32'd4838718;
        phase_inc_lut[ 27] = 32'd4665907;  phase_inc_lut[ 28] = 32'd4505014;  phase_inc_lut[ 29] = 32'd4354846;
        phase_inc_lut[ 30] = 32'd4214368;  phase_inc_lut[ 31] = 32'd4082669;  phase_inc_lut[ 32] = 32'd3958951;
        phase_inc_lut[ 33] = 32'd3842512;  phase_inc_lut[ 34] = 32'd3732726;  phase_inc_lut[ 35] = 32'd3629039;
        phase_inc_lut[ 36] = 32'd3530957;  phase_inc_lut[ 37] = 32'd3438037;  phase_inc_lut[ 38] = 32'd3349882;
        phase_inc_lut[ 39] = 32'd3266135;  phase_inc_lut[ 40] = 32'd3186473;  phase_inc_lut[ 41] = 32'd3110605;
        phase_inc_lut[ 42] = 32'd3038265;  phase_inc_lut[ 43] = 32'd2969213;  phase_inc_lut[ 44] = 32'd2903231;
        phase_inc_lut[ 45] = 32'd2840117;  phase_inc_lut[ 46] = 32'd2779689;  phase_inc_lut[ 47] = 32'd2721779;
        phase_inc_lut[ 48] = 32'd2666233;  phase_inc_lut[ 49] = 32'd2612908;  phase_inc_lut[ 50] = 32'd2561674;
        phase_inc_lut[ 51] = 32'd2512411;  phase_inc_lut[ 52] = 32'd2465007;  phase_inc_lut[ 53] = 32'd2419359;
        phase_inc_lut[ 54] = 32'd2375371;  phase_inc_lut[ 55] = 32'd2332953;  phase_inc_lut[ 56] = 32'd2292024;
        phase_inc_lut[ 57] = 32'd2252507;  phase_inc_lut[ 58] = 32'd2214329;  phase_inc_lut[ 59] = 32'd2177423;
        phase_inc_lut[ 60] = 32'd2141728;  phase_inc_lut[ 61] = 32'd2107184;  phase_inc_lut[ 62] = 32'd2073736;
        phase_inc_lut[ 63] = 32'd2041334;  phase_inc_lut[ 64] = 32'd2009929;  phase_inc_lut[ 65] = 32'd1979476;
        phase_inc_lut[ 66] = 32'd1949931;  phase_inc_lut[ 67] = 32'd1921256;  phase_inc_lut[ 68] = 32'd1893411;
        phase_inc_lut[ 69] = 32'd1866363;  phase_inc_lut[ 70] = 32'd1840076;  phase_inc_lut[ 71] = 32'd1814519;
        phase_inc_lut[ 72] = 32'd1789663;  phase_inc_lut[ 73] = 32'd1765478;  phase_inc_lut[ 74] = 32'd1741939;
        phase_inc_lut[ 75] = 32'd1719018;  phase_inc_lut[ 76] = 32'd1696693;  phase_inc_lut[ 77] = 32'd1674941;
        phase_inc_lut[ 78] = 32'd1653739;  phase_inc_lut[ 79] = 32'd1633067;  phase_inc_lut[ 80] = 32'd1612906;
        phase_inc_lut[ 81] = 32'd1593237;  phase_inc_lut[ 82] = 32'd1574041;  phase_inc_lut[ 83] = 32'd1555302;
        phase_inc_lut[ 84] = 32'd1537005;  phase_inc_lut[ 85] = 32'd1519132;  phase_inc_lut[ 86] = 32'd1501671;
        phase_inc_lut[ 87] = 32'd1484607;  phase_inc_lut[ 88] = 32'd1467926;  phase_inc_lut[ 89] = 32'd1451615;
        phase_inc_lut[ 90] = 32'd1435664;  phase_inc_lut[ 91] = 32'd1420059;  phase_inc_lut[ 92] = 32'd1404789;
        phase_inc_lut[ 93] = 32'd1389845;  phase_inc_lut[ 94] = 32'd1375215;  phase_inc_lut[ 95] = 32'd1360890;
        phase_inc_lut[ 96] = 32'd1346860;  phase_inc_lut[ 97] = 32'd1333116;  phase_inc_lut[ 98] = 32'd1319650;
        phase_inc_lut[ 99] = 32'd1306454;  phase_inc_lut[100] = 32'd1293519;  phase_inc_lut[101] = 32'd1280837;
        phase_inc_lut[102] = 32'd1268402;  phase_inc_lut[103] = 32'd1256206;  phase_inc_lut[104] = 32'd1244242;
        phase_inc_lut[105] = 32'd1232504;  phase_inc_lut[106] = 32'd1220985;  phase_inc_lut[107] = 32'd1209680;
        phase_inc_lut[108] = 32'd1198582;  phase_inc_lut[109] = 32'd1187685;  phase_inc_lut[110] = 32'd1176986;
        phase_inc_lut[111] = 32'd1166477;  phase_inc_lut[112] = 32'd1156154;  phase_inc_lut[113] = 32'd1146012;
        phase_inc_lut[114] = 32'd1136047;  phase_inc_lut[115] = 32'd1126253;  phase_inc_lut[116] = 32'd1116627;
        phase_inc_lut[117] = 32'd1107164;  phase_inc_lut[118] = 32'd1097860;  phase_inc_lut[119] = 32'd1088712;
        phase_inc_lut[120] = 32'd1079714;  phase_inc_lut[121] = 32'd1070864;  phase_inc_lut[122] = 32'd1062158;
        phase_inc_lut[123] = 32'd1053592;  phase_inc_lut[124] = 32'd1045163;  phase_inc_lut[125] = 32'd1036868;
        phase_inc_lut[126] = 32'd1028704;  phase_inc_lut[127] = 32'd1020667;  phase_inc_lut[128] = 32'd1012755;
        phase_inc_lut[129] = 32'd1004965;  phase_inc_lut[130] = 32'd997293;   phase_inc_lut[131] = 32'd989738;
        phase_inc_lut[132] = 32'd982296;   phase_inc_lut[133] = 32'd974966;   phase_inc_lut[134] = 32'd967744;
        phase_inc_lut[135] = 32'd960628;   phase_inc_lut[136] = 32'd953616;   phase_inc_lut[137] = 32'd946706;
        phase_inc_lut[138] = 32'd939895;   phase_inc_lut[139] = 32'd933181;   phase_inc_lut[140] = 32'd926563;
        phase_inc_lut[141] = 32'd920038;   phase_inc_lut[142] = 32'd913604;   phase_inc_lut[143] = 32'd907260;
        phase_inc_lut[144] = 32'd901003;   phase_inc_lut[145] = 32'd894831;   phase_inc_lut[146] = 32'd888744;
        phase_inc_lut[147] = 32'd882739;   phase_inc_lut[148] = 32'd876815;   phase_inc_lut[149] = 32'd870969;
        phase_inc_lut[150] = 32'd865201;   phase_inc_lut[151] = 32'd859509;   phase_inc_lut[152] = 32'd853891;
        phase_inc_lut[153] = 32'd848347;   phase_inc_lut[154] = 32'd842874;   phase_inc_lut[155] = 32'd837470;
        phase_inc_lut[156] = 32'd832136;   phase_inc_lut[157] = 32'd826870;   phase_inc_lut[158] = 32'd821669;
        phase_inc_lut[159] = 32'd816534;   phase_inc_lut[160] = 32'd811462;   phase_inc_lut[161] = 32'd806453;
        phase_inc_lut[162] = 32'd801505;   phase_inc_lut[163] = 32'd796618;   phase_inc_lut[164] = 32'd791790;
        phase_inc_lut[165] = 32'd787020;   phase_inc_lut[166] = 32'd782308;   phase_inc_lut[167] = 32'd777651;
        phase_inc_lut[168] = 32'd773050;   phase_inc_lut[169] = 32'd768502;   phase_inc_lut[170] = 32'd764008;
        phase_inc_lut[171] = 32'd759566;   phase_inc_lut[172] = 32'd755176;   phase_inc_lut[173] = 32'd750836;
        phase_inc_lut[174] = 32'd746545;   phase_inc_lut[175] = 32'd742303;   phase_inc_lut[176] = 32'd738110;
        phase_inc_lut[177] = 32'd733963;   phase_inc_lut[178] = 32'd729863;   phase_inc_lut[179] = 32'd725808;
        phase_inc_lut[180] = 32'd721798;   phase_inc_lut[181] = 32'd717832;   phase_inc_lut[182] = 32'd713909;
        phase_inc_lut[183] = 32'd710029;   phase_inc_lut[184] = 32'd706191;   phase_inc_lut[185] = 32'd702395;
        phase_inc_lut[186] = 32'd698638;   phase_inc_lut[187] = 32'd694922;   phase_inc_lut[188] = 32'd691245;
        phase_inc_lut[189] = 32'd687607;   phase_inc_lut[190] = 32'd684007;   phase_inc_lut[191] = 32'd680445;
        phase_inc_lut[192] = 32'd676919;   phase_inc_lut[193] = 32'd673430;   phase_inc_lut[194] = 32'd669976;
        phase_inc_lut[195] = 32'd666558;   phase_inc_lut[196] = 32'd663175;   phase_inc_lut[197] = 32'd659825;
        phase_inc_lut[198] = 32'd656510;   phase_inc_lut[199] = 32'd653227;   phase_inc_lut[200] = 32'd649977;
        phase_inc_lut[201] = 32'd646759;   phase_inc_lut[202] = 32'd643573;   phase_inc_lut[203] = 32'd640419;
        phase_inc_lut[204] = 32'd637295;   phase_inc_lut[205] = 32'd634201;   phase_inc_lut[206] = 32'd631137;
        phase_inc_lut[207] = 32'd628103;   phase_inc_lut[208] = 32'd625098;   phase_inc_lut[209] = 32'd622121;
        phase_inc_lut[210] = 32'd619172;   phase_inc_lut[211] = 32'd616252;   phase_inc_lut[212] = 32'd613359;
        phase_inc_lut[213] = 32'd610492;   phase_inc_lut[214] = 32'd607653;   phase_inc_lut[215] = 32'd604840;
        phase_inc_lut[216] = 32'd602053;   phase_inc_lut[217] = 32'd599291;   phase_inc_lut[218] = 32'd596554;
        phase_inc_lut[219] = 32'd593843;   phase_inc_lut[220] = 32'd591156;   phase_inc_lut[221] = 32'd588493;
        phase_inc_lut[222] = 32'd585854;   phase_inc_lut[223] = 32'd583238;   phase_inc_lut[224] = 32'd580646;
        phase_inc_lut[225] = 32'd578077;   phase_inc_lut[226] = 32'd575530;   phase_inc_lut[227] = 32'd573006;
        phase_inc_lut[228] = 32'd570504;   phase_inc_lut[229] = 32'd568023;   phase_inc_lut[230] = 32'd565564;
        phase_inc_lut[231] = 32'd563127;   phase_inc_lut[232] = 32'd560710;   phase_inc_lut[233] = 32'd558314;
        phase_inc_lut[234] = 32'd555938;   phase_inc_lut[235] = 32'd553582;   phase_inc_lut[236] = 32'd551246;
        phase_inc_lut[237] = 32'd548930;   phase_inc_lut[238] = 32'd546633;   phase_inc_lut[239] = 32'd544356;
        phase_inc_lut[240] = 32'd542097;   phase_inc_lut[241] = 32'd539857;   phase_inc_lut[242] = 32'd537635;
        phase_inc_lut[243] = 32'd535432;   phase_inc_lut[244] = 32'd533247;   phase_inc_lut[245] = 32'd531079;
        phase_inc_lut[246] = 32'd528929;   phase_inc_lut[247] = 32'd526796;   phase_inc_lut[248] = 32'd524680;
        phase_inc_lut[249] = 32'd522582;   phase_inc_lut[250] = 32'd520500;   phase_inc_lut[251] = 32'd518434;
        phase_inc_lut[252] = 32'd516385;   phase_inc_lut[253] = 32'd514352;   phase_inc_lut[254] = 32'd512335;
        phase_inc_lut[255] = 32'd510334;
    end

    //////////////////////////////////////////////////////////////////////////
    // Music clock + offset advance (matches MAME tone_clock_expire logic)
    //////////////////////////////////////////////////////////////////////////
    always @(posedge clk) begin
        if (reset) begin
            music_cnt <= 0;
        end else if (music_tick) begin
            music_cnt <= 0;
        end else begin
            music_cnt <= music_cnt + 1'd1;
        end
    end

    //////////////////////////////////////////////////////////////////////////
    // ROM fetch sequencer – one address per clock after music_tick
    // Guarantees fresh period byte for each channel after offset update
    // (critical for correct pitch stepping)
    //////////////////////////////////////////////////////////////////////////
    always @(posedge clk) begin
        if (reset) begin
            rom_sel       <= 0;
            rom_latch_sel <= 0;
        end else if (music_tick) begin
            rom_sel <= 0;
        end else if (rom_sel < 2) begin
            rom_sel <= rom_sel + 1'd1;
        end
        rom_latch_sel <= rom_sel;
    end

    // Latch ROM data (handles both combinatorial ROM and registered BRAM)
    always @(posedge clk) begin
        case (rom_latch_sel)
            0: ch_romdata[0] <= snd_rom_data;
            1: ch_romdata[1] <= snd_rom_data;
            2: ch_romdata[2] <= snd_rom_data;
        endcase
    end

    // Update phase_step from fresh ROM period byte (no floating point)
    always @(posedge clk) begin
        if (reset) begin
            ch_phase_step[0] <= 0;
            ch_phase_step[1] <= 0;
            ch_phase_step[2] <= 0;
        end else if (rom_latch_sel < 3) begin
            if (ch_romdata[rom_latch_sel] == 8'hff) begin
                ch_phase_step[rom_latch_sel] <= 0;
            end else begin
                idx = 8'd255 - ch_romdata[rom_latch_sel];
                ch_phase_step[rom_latch_sel] <= phase_inc_lut[idx];
            end
        end
    end

    // ROM address mux (single port – cycles through the three channels)
    wire [12:0] addr_calc [0:2];
    assign addr_calc[0] = ch_base[0] + (ch_offset[0] & ch_mask[0]);
    assign addr_calc[1] = ch_base[1] + (ch_offset[1] & ch_mask[1]);
    assign addr_calc[2] = ch_base[2] + (ch_offset[2] & ch_mask[2]);

    always @* begin
        case (rom_sel)
            0: snd_rom_addr = addr_calc[0];
            1: snd_rom_addr = addr_calc[1];
            2: snd_rom_addr = addr_calc[2];
            default: snd_rom_addr = 11'h000;
        endcase
    end

    //////////////////////////////////////////////////////////////////////////
    // Phase accumulators + waveform interpolation (exact MAME fixed-point math)
    // phase[31:0] – waveform index now taken from [27:24] per fix
    //////////////////////////////////////////////////////////////////////////
    always @(posedge clk) begin
        if (reset) begin
            ch_phase[0] <= 0; ch_phase[1] <= 0; ch_phase[2] <= 0;
        end else begin
            for (i = 0; i < 3; i = i + 1) begin
                if (!ch_mute[i]) begin
                    ch_phase[i] <= ch_phase[i] + ch_phase_step[i];
                end
            end
        end
    end

    //////////////////////////////////////////////////////////////////////////
    // Waveform rebuild state machine (replaces non-synthesizable build_waveform_task)
    // Exact MAME build_waveform formula for ch0/ch1; ch2 is always square
    //////////////////////////////////////////////////////////////////////////
    always @(posedge clk) begin
        if (reset) begin
            wf_busy  <= 1'b0;
            wf_state <= 5'd0;
        end else if (wf_wr && !wf_busy) begin
            ch0_wf_mask <= ch0_mask_calc;
            ch1_wf_mask <= wf_data[7:4];
            wf_busy  <= 1'b1;
            wf_state <= 5'd0;
        end else if (wf_busy) begin
            // compute waveform entry (exact MAME build_waveform formula)
            wf_m = wf_state[4] ? ch1_wf_mask : ch0_wf_mask;
            wf_j = wf_state[3:0];
            wf_bit3 = (wf_m[0] || wf_m[1]) ? 5'd8 : wf_m[2] ? 5'd4 : wf_m[3] ? 5'd2 : 5'd0;
            wf_bit2 = wf_m[2] ? 5'd8 : (wf_m[1] || wf_m[3]) ? 5'd4 : 5'd0;
            wf_bit1 = wf_m[3] ? 5'd8 : wf_m[2] ? 5'd4 : wf_m[1] ? 5'd2 : 5'd0;
            wf_bit0 = wf_bit1 >> 1;
            if ((wf_bit0 + wf_bit1 + wf_bit2 + wf_bit3) < 5'd16) begin
                wf_bit0 = wf_bit0 << 1;
                wf_bit1 = wf_bit1 << 1;
                wf_bit2 = wf_bit2 << 1;
                wf_bit3 = wf_bit3 << 1;
            end
            wf_base_val = (wf_bit0 + wf_bit1 + wf_bit2 + wf_bit3 + 5'd1) / 5'd2;
            wf_data_val = (wf_j[0] ? wf_bit0 : 5'd0) + (wf_j[1] ? wf_bit1 : 5'd0) + (wf_j[2] ? wf_bit2 : 5'd0) + (wf_j[3] ? wf_bit3 : 5'd0);
            ch_form[wf_state[4]][wf_j] <= ($signed(wf_data_val) - $signed(wf_base_val)) * 16'sd409;
            wf_state <= wf_state + 5'd1;
            if (wf_state == 5'd31) begin
                wf_busy <= 1'b0;
            end
        end
    end

    //////////////////////////////////////////////////////////////////////////
    // CPU port writes – decoded exactly as fantasy_sound_device::sound_w
    // (Nibbler/Fantasy path). wr3 handles ch2 base.
    //////////////////////////////////////////////////////////////////////////
    always @(posedge clk) begin
        if (reset) begin
            // initial state (MAME device_start + set_music_freq)
            ch_mute[0]   <= 1'b1;
            ch_mute[1]   <= 1'b1;
            ch_mute[2]   <= 1'b1;
            ch_offset[0] <= 0; ch_offset[1] <= 0; ch_offset[2] <= 0;
            ch_mask[0]   <= 8'hff; ch_mask[1] <= 8'hff; ch_mask[2] <= 8'hff;
            ch_base[0]   <= 11'h0000;
            ch_base[1]   <= 11'h0800;
            ch_base[2]   <= 11'h1000;          // ch2 starts at $1000 (high bits set on writes)

            // Channel 2 is always a square wave (MAME special case). Initialize at reset.
            // ch0/ch1 will be rebuilt on first wr2 (MAME build_waveform called later).
            for (j = 0; j < 16; j = j + 1) begin
                ch_form[2][j] <= j[3] ? 16'sd7 * 16'sd409 : -16'sd8 * 16'sd409;
            end
        end else begin
            if (music_tick) begin
                ch_offset[0] <= (ch_offset[0] + 1'd1) & ch_mask[0];
                ch_offset[1] <= (ch_offset[1] + 1'd1) & ch_mask[1];
                ch_offset[2] <= (ch_offset[2] + 1'd1) & ch_mask[2];
            end
            if (wr0) begin
                // fantasy offset 0
                ch_base[0]   <= {sound_port0[2:0], 8'h00};
                ch_mute[0]   <= ~sound_port0[3];
                if (sound_port0[3] == 1'b0) ch_offset[0] <= 0;   // muting ch0
                ch_mute[2]   <= ~sound_port0[4];
                if (sound_port0[4] == 1'b0) ch_offset[2] <= 0;   // muting ch2
            end

            if (wr1) begin
                // fantasy offset 1
                ch_base[1]   <= 13'h0800 | {sound_port1[2:0], 8'h00};
                ch_mute[1]   <= ~sound_port1[3];
                if (sound_port1[3] == 1'b0) ch_offset[1] <= 0;   // muting ch1
            end

            if (wr2) begin
                // fantasy offset 2 – latch waveform data (triggers rebuild state machine)
                wf_data <= sound_port2;
                wf_wr   <= 1'b1;
            end

            if (wr3) begin
                // fantasy offset 3 – ch2 base high bits ($1000 region)
                ch_base[2]   <= 13'h1000 | {sound_port3[6:4], 5'h00};
            end
        end
    end

    //////////////////////////////////////////////////////////////////////////
    // Audio output – 3-channel interpolated sum (exact MAME sound_stream_update)
    // Waveform index now [27:24], frac now [23:8] per fix
    //////////////////////////////////////////////////////////////////////////
    always @(posedge clk) begin
        if (reset) begin
            audio_out <= 0;
        end else begin
            sum = 0;
            for (i = 0; i < 3; i = i + 1) begin
                if (!ch_mute[i] && ch_phase_step[i] != 0) begin
                    cur_pos = ch_phase[i] + ch_phase_step[i];
                    prev_idx = ch_phase[i][27:24];
                    cur_idx  = cur_pos[27:24];
                    prev_val = ch_form[i][prev_idx];
                    cur_val  = ch_form[i][cur_idx];
                    frac = cur_pos[23:8];
                    interp = ((prev_val * (FRAC_ONE - frac)) +
                              (cur_val  * frac)) >> FRAC_BITS;
                    sum = sum + interp;
                end
            end
            audio_out <= sum[18:3];   // fits comfortably in 16-bit signed range
        end
    end

endmodule