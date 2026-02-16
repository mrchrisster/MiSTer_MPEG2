
module uart_debug (
    input clk,          // 27 MHz
    input rst_n,
    input locked,
    input active,
    input [12:0] arx,
    input [12:0] ary,
    input        busy,
    input        valid,
    // Additional debug signals
    input [8:0]  init_cnt,
    input        sync_rst,
    input        vbw_almost_full,
    input        mem_req_en,
    input        mem_req_valid,
    input        mem_res_almost_full,  // Response FIFO backpressure
    input [3:0]  shim_state,           // Memory shim state machine
    input        sdram_busy,           // SDRAM controller busy signal
    input        sdram_ack,            // SDRAM controller ack signal
    // MPG streamer debug
    input        streamer_active,      // File streaming active
    input        streamer_sd_rd,       // SD read request
    input        streamer_sd_ack,      // SD acknowledge
    input        streamer_has_data,    // Cache has data
    input [15:0] streamer_file_size,   // File size (lower 16 bits)
    input [15:0] streamer_total_sectors, // Total sectors
    input [15:0] streamer_next_lba,    // Next LBA to read
    // Memory read/write counters
    input [15:0] mem_rd_count,         // 64-bit read completions
    input [15:0] mem_wr_count,         // 64-bit write completions
    // HDMI debug
    input        hdmi_lock,
    input        hdmi_vs,
    input        hdmi_de,
    input        hdmi_hs,
    output tx_pin
);

    wire tx_ready;
    reg [7:0] tx_data;
    reg tx_valid;

    uart_tx #(
        .CLK_FRE(27),
        .BAUD_RATE(115200)
    ) uart_inst (
        .clk(clk),
        .rst_n(rst_n),
        .tx_data(tx_data),
        .tx_data_valid(tx_valid),
        .tx_data_ready(tx_ready),
        .tx_pin(tx_pin)
    );

    // Update timer: every ~1 second (27,000,000 cycles)
    reg [24:0] timer;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) timer <= 0;
        else if (timer == 27000000) timer <= 0;
        else timer <= timer + 1;
    end

    // Capture values when timer hits 0 to ensure stable output during transmission
    reg locked_r, active_r, busy_r, valid_r;
    reg [12:0] arx_r, ary_r;
    reg [8:0] init_cnt_r;
    reg sync_rst_r, vbw_almost_full_r, mem_req_en_r, mem_req_valid_r, mem_res_almost_full_r;
    reg [3:0] shim_state_r;
    reg sdram_busy_r, sdram_ack_r;
    reg streamer_active_r, streamer_sd_rd_r, streamer_sd_ack_r, streamer_has_data_r;
    reg [15:0] streamer_file_size_r, streamer_total_sectors_r, streamer_next_lba_r;
    reg [15:0] mem_rd_count_r, mem_wr_count_r;
    reg hdmi_lock_r, hdmi_vs_r, hdmi_de_r, hdmi_hs_r;

    // State machine
    localparam S_IDLE = 0;
    localparam S_PRINT = 1;
    localparam S_WAIT_TX = 2; // Wait for ready to go low (ack) then high (done)
    
    reg [3:0] state = S_IDLE;
    reg [6:0] char_idx = 0;  // 7 bits to hold indices 0-103

    // Message Format: "L:x A:x B:x V:x X:xxx Y:xxx I:xxx S:x F:x E:x Q:x R:x M:x U:x K:x T:x D:x C:x H:x W:xxxx P:xxxx J:xxxx\r\n"
    // I=init_cnt S=sync_rst F=vbw_almost_full E=mem_req_en Q=mem_req_valid R=mem_res_almost_full
    // M=shim_state U=sdram_busy K=sdram_ack
    // T=sTreamer_active D=sd_rD C=sd_aCk H=cache_Has_data
    // W=mem_Writes P=mem_reads(P) J=next_lba(Jump)
    
    function [7:0] to_hex;
        input [3:0] val;
        begin
            to_hex = (val < 10) ? ("0" + val) : ("A" + val - 10);
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            tx_valid <= 0;
            char_idx <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    tx_valid <= 0;
                    if (timer == 0) begin
                        locked_r <= locked;
                        active_r <= active;
                        busy_r <= busy;
                        valid_r <= valid;
                        arx_r <= arx;
                        ary_r <= ary;
                        init_cnt_r <= init_cnt;
                        sync_rst_r <= sync_rst;
                        vbw_almost_full_r <= vbw_almost_full;
                        mem_req_en_r <= mem_req_en;
                        mem_req_valid_r <= mem_req_valid;
                        mem_res_almost_full_r <= mem_res_almost_full;
                        shim_state_r <= shim_state;
                        sdram_busy_r <= sdram_busy;
                        sdram_ack_r <= sdram_ack;
                        streamer_active_r <= streamer_active;
                        streamer_sd_rd_r <= streamer_sd_rd;
                        streamer_sd_ack_r <= streamer_sd_ack;
                        streamer_has_data_r <= streamer_has_data;
                        streamer_file_size_r <= streamer_file_size;
                        streamer_total_sectors_r <= streamer_total_sectors;
                        streamer_next_lba_r <= streamer_next_lba;
                        mem_rd_count_r <= mem_rd_count;
                        mem_wr_count_r <= mem_wr_count;
                        hdmi_lock_r <= hdmi_lock;
                        hdmi_vs_r <= hdmi_vs;
                        hdmi_de_r <= hdmi_de;
                        hdmi_hs_r <= hdmi_hs;
                        char_idx <= 0;
                        state <= S_PRINT;
                    end
                end

                S_PRINT: begin
                    if (tx_ready) begin
                        state <= S_WAIT_TX;
                        tx_valid <= 1;
                        case (char_idx)
                            0: tx_data <= "L";
                            1: tx_data <= ":";
                            2: tx_data <= locked_r ? "1" : "0";
                            3: tx_data <= " ";
                            4: tx_data <= "A";
                            5: tx_data <= ":";
                            6: tx_data <= active_r ? "1" : "0";
                            7: tx_data <= " ";
                            8: tx_data <= "B";
                            9: tx_data <= ":";
                            10: tx_data <= busy_r ? "1" : "0";
                            11: tx_data <= " ";
                            12: tx_data <= "V";
                            13: tx_data <= ":";
                            14: tx_data <= valid_r ? "1" : "0";
                            15: tx_data <= " ";
                            16: tx_data <= "X";
                            17: tx_data <= ":";
                            18: tx_data <= to_hex(arx_r[11:8]);
                            19: tx_data <= to_hex(arx_r[7:4]);
                            20: tx_data <= to_hex(arx_r[3:0]);
                            21: tx_data <= " ";
                            22: tx_data <= "Y";
                            23: tx_data <= ":";
                            24: tx_data <= to_hex(ary_r[11:8]);
                            25: tx_data <= to_hex(ary_r[7:4]);
                            26: tx_data <= to_hex(ary_r[3:0]);
                            27: tx_data <= " ";
                            28: tx_data <= "I";
                            29: tx_data <= ":";
                            30: tx_data <= to_hex({3'b0, init_cnt_r[8]});
                            31: tx_data <= to_hex(init_cnt_r[7:4]);
                            32: tx_data <= to_hex(init_cnt_r[3:0]);
                            33: tx_data <= " ";
                            34: tx_data <= "S";
                            35: tx_data <= ":";
                            36: tx_data <= sync_rst_r ? "1" : "0";
                            37: tx_data <= " ";
                            38: tx_data <= "F";
                            39: tx_data <= ":";
                            40: tx_data <= vbw_almost_full_r ? "1" : "0";
                            41: tx_data <= " ";
                            42: tx_data <= "E";
                            43: tx_data <= ":";
                            44: tx_data <= mem_req_en_r ? "1" : "0";
                            45: tx_data <= " ";
                            46: tx_data <= "Q";
                            47: tx_data <= ":";
                            48: tx_data <= mem_req_valid_r ? "1" : "0";
                            49: tx_data <= " ";
                            50: tx_data <= "R";
                            51: tx_data <= ":";
                            52: tx_data <= mem_res_almost_full_r ? "1" : "0";
                            53: tx_data <= " ";
                            54: tx_data <= "M";
                            55: tx_data <= ":";
                            56: tx_data <= to_hex(shim_state_r);
                            57: tx_data <= " ";
                            58: tx_data <= "U"; // bUsy
                            59: tx_data <= ":";
                            60: tx_data <= sdram_busy_r ? "1" : "0";
                            61: tx_data <= " ";
                            62: tx_data <= "K"; // acK
                            63: tx_data <= ":";
                            64: tx_data <= sdram_ack_r ? "1" : "0";
                            65: tx_data <= " ";
                            66: tx_data <= "T"; // sTreamer active
                            67: tx_data <= ":";
                            68: tx_data <= streamer_active_r ? "1" : "0";
                            69: tx_data <= " ";
                            70: tx_data <= "D"; // sd_rD
                            71: tx_data <= ":";
                            72: tx_data <= streamer_sd_rd_r ? "1" : "0";
                            73: tx_data <= " ";
                            74: tx_data <= "C"; // sd_aCk
                            75: tx_data <= ":";
                            76: tx_data <= streamer_sd_ack_r ? "1" : "0";
                            77: tx_data <= " ";
                            78: tx_data <= "H"; // cache_Has_data
                            79: tx_data <= ":";
                            80: tx_data <= streamer_has_data_r ? "1" : "0";
                            81: tx_data <= " ";
                            82: tx_data <= "W"; // Write count
                            83: tx_data <= ":";
                            84: tx_data <= to_hex(mem_wr_count_r[15:12]);
                            85: tx_data <= to_hex(mem_wr_count_r[11:8]);
                            86: tx_data <= to_hex(mem_wr_count_r[7:4]);
                            87: tx_data <= to_hex(mem_wr_count_r[3:0]);
                            88: tx_data <= " ";
                            89: tx_data <= "P"; // read(P) count
                            90: tx_data <= ":";
                            91: tx_data <= to_hex(mem_rd_count_r[15:12]);
                            92: tx_data <= to_hex(mem_rd_count_r[11:8]);
                            93: tx_data <= to_hex(mem_rd_count_r[7:4]);
                            94: tx_data <= to_hex(mem_rd_count_r[3:0]);
                            95: tx_data <= " ";
                            96: tx_data <= "J"; // next_lba(Jump)
                            97: tx_data <= ":";
                            98: tx_data <= to_hex(streamer_next_lba_r[15:12]);
                            99: tx_data <= to_hex(streamer_next_lba_r[11:8]);
                            100: tx_data <= to_hex(streamer_next_lba_r[7:4]);
                            101: tx_data <= to_hex(streamer_next_lba_r[3:0]);
                            102: tx_data <= " ";
                            103: tx_data <= "Z"; // HDMI debug hex: lock, vs, de, hs
                            104: tx_data <= ":";
                            105: tx_data <= to_hex({hdmi_lock_r, hdmi_vs_r, hdmi_de_r, hdmi_hs_r});
                            106: tx_data <= "\r";
                            107: tx_data <= "\n";
                            default: begin
                                state <= S_IDLE;
                                tx_valid <= 0;
                            end
                        endcase
                    end
                end

                S_WAIT_TX: begin
                    tx_valid <= 0;
                    state <= S_PRINT; 
                    char_idx <= char_idx + 1;
                end
            endcase
        end
    end

endmodule
