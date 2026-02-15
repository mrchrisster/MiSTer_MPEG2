module mem_shim (
    input             clk,
    input             rst_n,

    // MPEG2 Core memory request FIFO (read side) — clocked on clk (mem_clk)
    input       [1:0] mem_req_rd_cmd,
    input      [21:0] mem_req_rd_addr,
    input      [63:0] mem_req_rd_dta,
    output reg        mem_req_rd_en,
    input             mem_req_rd_valid,

    // MPEG2 Core memory response FIFO (write side) — clocked on clk (mem_clk)
    output reg [63:0] mem_res_wr_dta,
    output reg        mem_res_wr_en,
    input             mem_res_wr_almost_full,

    // DDR3 Controller Interface (Avalon-MM 64-bit)
    output     [28:0] ddr3_addr,
    output      [7:0] ddr3_burstcnt,
    output            ddr3_read,
    output            ddr3_write,
    output     [63:0] ddr3_writedata,
    output      [7:0] ddr3_byteenable,
    input      [63:0] ddr3_readdata,
    input             ddr3_readdatavalid,
    input             ddr3_waitrequest,

    // Debug outputs
    output     [3:0]  debug_state,
    output            debug_sdram_busy,
    output            debug_sdram_ack,
    output    [15:0]  debug_rd_count,
    output    [15:0]  debug_wr_count
);

    // Command encoding (from mem_codes.v)
    localparam CMD_NOOP    = 2'd0;
    localparam CMD_REFRESH = 2'd1;
    localparam CMD_READ    = 2'd2;
    localparam CMD_WRITE   = 2'd3;

    // =========================================================================
    // DDR3 Avalon-MM outputs
    // =========================================================================
    reg        ram_read;
    reg        ram_write;
    reg [28:0] ram_address;
    reg [63:0] ram_writedata;

    assign ddr3_read       = ram_read;
    assign ddr3_write      = ram_write;
    assign ddr3_addr       = ram_address;
    assign ddr3_writedata  = ram_writedata;
    assign ddr3_burstcnt   = 8'd1;
    assign ddr3_byteenable = 8'hFF;

    // =========================================================================
    // FSM
    // =========================================================================
    // state=0 (IDLE): Accept new FIFO commands
    // state=1 (WAIT): Wait for transaction acceptance (!waitrequest)

    reg state;

    always @(posedge clk) begin
        if (!rst_n) begin
            state         <= 0;
            ram_read      <= 0;
            ram_write     <= 0;
            ram_address   <= 0;
            ram_writedata <= 0;
            mem_req_rd_en <= 0;
            mem_res_wr_en <= 0;
            mem_res_wr_dta <= 0;
        end
        else begin
            // -----------------------------------------------------------------
            // Response Path (Always Active)
            // -----------------------------------------------------------------
            mem_res_wr_en <= ddr3_readdatavalid;
            if (ddr3_readdatavalid)
                mem_res_wr_dta <= ddr3_readdata;

            // -----------------------------------------------------------------
            // Command Path
            // -----------------------------------------------------------------
            if (!state) begin
                // IDLE State
                // Default: Keep popping if response FIFO has space
                mem_req_rd_en <= !mem_res_wr_almost_full;

                if (mem_req_rd_valid && !mem_res_wr_almost_full) begin
                    case (mem_req_rd_cmd)
                        CMD_WRITE: begin
                            ram_write     <= 1;
                            ram_address   <= {4'b0011, mem_req_rd_addr, 3'b000};
                            ram_writedata <= mem_req_rd_dta;
                            state         <= 1;     // Go to WAIT
                            mem_req_rd_en <= 0;     // Stop popping
                        end
                        CMD_READ: begin
                            ram_read      <= 1;
                            ram_address   <= {4'b0011, mem_req_rd_addr, 3'b000};
                            state         <= 1;     // Go to WAIT
                            mem_req_rd_en <= 0;     // Stop popping
                        end
                        // Ignore NOOP/REFRESH, keep popping
                        default: ;
                    endcase
                end
            end
            else begin
                // WAIT State
                if (!ddr3_waitrequest) begin
                    // Transaction Accepted
                    ram_read  <= 0;
                    ram_write <= 0;
                    state     <= 0; // Back to IDLE
                    
                    // Resume flow control (look ahead for next cycle)
                    mem_req_rd_en <= !mem_res_wr_almost_full;
                end
                // Else: Stay in WAIT, holding ram_read/write/addr/data stable
            end
        end
    end

    // =========================================================================
    // Debug
    // =========================================================================
    reg [15:0] rd_count;
    reg [15:0] wr_count;

    wire rd_accepted = ddr3_read  && !ddr3_waitrequest;
    wire wr_accepted = ddr3_write && !ddr3_waitrequest;

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_count <= 0;
            wr_count <= 0;
        end else begin
            if (rd_accepted) rd_count <= rd_count + 1'd1;
            if (wr_accepted) wr_count <= wr_count + 1'd1;
        end
    end

    assign debug_state      = {3'b000, state};
    assign debug_sdram_busy = ddr3_waitrequest;
    assign debug_sdram_ack  = rd_accepted | wr_accepted;
    assign debug_rd_count   = rd_count;
    assign debug_wr_count   = wr_count;

endmodule
