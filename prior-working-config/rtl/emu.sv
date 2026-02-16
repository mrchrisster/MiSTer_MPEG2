module emu (
	input         CLK_50M,
	input         RESET,
	inout  [48:0] HPS_BUS,

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,
	output        VGA_DISABLE,

	output        CLK_SYS,
	output        CLK_MEM,

	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output  [1:0] VGA_SL,
	output        VGA_SCALER,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nWE,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,

	input  [1:0]  BUTTONS,

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output        AUDIO_MIX,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,


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

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	output [6:0]  USER_OUT,
	input  [6:0]  USER_IN,

	input         OSD_STATUS,

	output        CLK_VIDEO,
	output        CE_PIXEL,

	input         CLK_AUDIO,
	output        LOCKED
);

// =========================================================================
// Default assignments for unused interfaces
// =========================================================================
assign VIDEO_ARX    = 13'd4;
assign VIDEO_ARY    = 13'd3;

assign VGA_F1       = 0;
assign VGA_SL       = 0;
assign VGA_SCALER   = 1; // Enable scaler for universal HDMI compatibility
assign VGA_DISABLE  = 0;
assign HDMI_FREEZE      = 0;
assign HDMI_BLACKOUT    = 0;
assign HDMI_BOB_DEINT   = 0;

// LED and status assignments consolidated at the end of module

assign AUDIO_S      = 0;
assign AUDIO_MIX    = 0;
assign AUDIO_L      = 0;
assign AUDIO_R      = 0;

assign SD_SCK       = 0;
assign SD_MOSI      = 0;
assign SD_CS        = 1;

// SDRAM Interface -- Unused
assign SDRAM_CLK    = 0;
assign SDRAM_CKE    = 0;
assign SDRAM_A      = 0;
assign SDRAM_BA     = 0;
assign SDRAM_DQ     = 16'bZ;
assign SDRAM_DQML   = 0;
assign SDRAM_DQMH   = 0;
assign SDRAM_nCS    = 1;
assign SDRAM_nWE    = 1;
assign SDRAM_nCAS   = 1;
assign SDRAM_nRAS   = 1;

assign UART_RTS     = 1;
assign UART_DTR     = 1;
// assign UART_TXD     = 1;

// Debug: Stream loading status on USER_OUT pins
// assign USER_OUT     = {3'b0, streamer_active, streamer_sd_rd, streamer_sd_ack, streamer_has_data};

// =========================================================================
// Clocks and Reset
// =========================================================================
wire clk_sys, clk_mem, clk_vid, locked;

sys_pll sys_pll (
    .refclk   (CLK_50M),
    .rst      (1'b0),
    .outclk_0 (clk_sys),  // 27 MHz
    .outclk_1 (clk_mem),  // 108 MHz
    .outclk_2 (clk_vid),  // 25.175 MHz
    .locked   (locked)
);

// Memory clock drives DDR3 interface
assign DDRAM_CLK = clk_mem;

// Active-low reset for the mpeg2video core
// The core's internal reset module handles watchdog_rst independently,
// so we must NOT feed watchdog_rst back into rst to avoid a latch-up:
// watchdog fires -> reset_n LOW -> async_rst LOW -> hard_rst LOW -> watchdog stuck
wire watchdog_rst;
wire reset_n = locked & ~RESET;

assign CLK_VIDEO = clk_vid;  // 25.175 MHz - standard VGA for HDMI compatibility
assign CE_PIXEL  = 1'b1;

// =========================================================================
// HPS IO — OSD menu and file loading
// =========================================================================
parameter CONF_STR = {
    "MPEG2;;",
    "S0,MPG M2V,Load Video;",
    "O1,Aspect Ratio,4:3,16:9;",
    "O[10],Direct Video,Off,On;",
    "R0,Reset;",
    "V,v1.0;"
};

wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wr;
wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wait = 1'b0;
wire        direct_video;

wire  [1:0] buttons;
wire [31:0] status;
wire [31:0] joystick_0;

// SD sector interface signals
wire [31:0] sd_lba;
wire        sd_rd;
wire        sd_ack;
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire        sd_buff_wr;
wire  [0:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;

hps_io #(.CONF_STR(CONF_STR)) hps_io_inst (
    .clk_sys        (clk_sys),
    .HPS_BUS        (HPS_BUS),

    .ioctl_download (ioctl_download),
    .ioctl_wr       (ioctl_wr),
    .ioctl_addr     (ioctl_addr),
    .ioctl_dout     (ioctl_dout),
    .ioctl_index    (ioctl_index),
    .ioctl_wait     (ioctl_wait),

    .buttons        (buttons),
    .status         (status),
    .joystick_0     (joystick_0),

    .forced_scandoubler(),
    .gamma_bus(),
    .direct_video   (direct_video),

    // SD sector-level access (virtual disk for MPG streaming)
    .sd_lba         ('{sd_lba}),
    .sd_blk_cnt     ('{6'd0}),
    .sd_rd          (sd_rd),
    .sd_wr          (1'b0),
    .sd_ack         (sd_ack),
    .sd_buff_addr   (sd_buff_addr),
    .sd_buff_dout   (sd_buff_dout),
    .sd_buff_din    ('{8'd0}),
    .sd_buff_wr     (sd_buff_wr),

    // Image mount detection
    .img_mounted    (img_mounted),
    .img_readonly   (img_readonly),
    .img_size       (img_size)
);

// =========================================================================
// MPG Sector Streamer: sd_* interface -> stream_data for mpeg2video
// =========================================================================
wire [7:0] stream_data;
wire       stream_valid;
wire       core_busy;

// Detect image mount event (start streaming)
reg        img_mounted_prev;
wire       start_streaming = img_mounted[0] && !img_mounted_prev;
reg [63:0] current_file_size;

always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        img_mounted_prev  <= 1'b0;
        current_file_size <= 64'd0;
    end else begin
        img_mounted_prev <= img_mounted[0];
        if (img_mounted[0])
            current_file_size <= img_size;
    end
end

wire streamer_active, streamer_sd_rd, streamer_sd_ack, streamer_has_data;
wire [15:0] streamer_file_size, streamer_total_sectors, streamer_next_lba;

mpg_streamer mpg_streamer_inst (
    .clk            (clk_sys),
    .rst_n          (reset_n),

    .start          (start_streaming),
    .file_size      (current_file_size),

    .sd_lba         (sd_lba),
    .sd_rd          (sd_rd),
    .sd_ack         (sd_ack),
    .sd_buff_addr   (sd_buff_addr),
    .sd_buff_dout   (sd_buff_dout),
    .sd_buff_wr     (sd_buff_wr),

    .stream_data    (stream_data),
    .stream_valid   (stream_valid),
    .busy           (core_busy),

    .debug_active         (streamer_active),
    .debug_sd_rd          (streamer_sd_rd),
    .debug_sd_ack         (streamer_sd_ack),
    .debug_cache_has_data (streamer_has_data),
    .debug_file_size      (streamer_file_size),
    .debug_total_sectors  (streamer_total_sectors),
    .debug_next_lba       (streamer_next_lba)
);

// =========================================================================
// MPEG2 Video Decoder Core
// =========================================================================
wire [1:0]  core_mem_cmd;
wire [21:0] core_mem_addr;
wire [63:0] core_mem_dta_out;
wire        core_mem_en;
wire        core_mem_valid;
wire [63:0] shim_mem_dta;
wire        shim_mem_en;
wire        shim_mem_almost_full;

wire [7:0] core_r, core_g, core_b;
wire       core_h_sync, core_v_sync;
wire [11:0] core_h_pos, core_v_pos;
wire [8:0]  core_init_cnt;
wire        core_sync_rst;
wire        core_vbw_almost_full;
wire       core_pixel_en;
wire [3:0]  shim_debug_state;
wire        shim_debug_sdram_busy;
wire        shim_debug_sdram_ack;
wire [15:0] shim_debug_rd_count;
wire [15:0] shim_debug_wr_count;

mpeg2video mpeg2video_inst (
    .clk        (clk_sys),
    .mem_clk    (clk_mem),
    .dot_clk    (clk_vid),  // 25.175 MHz video output clock
    .rst        (reset_n),

    .stream_data  (stream_data),
    .stream_valid (stream_valid),

    .reg_addr   (4'b0),
    .reg_wr_en  (1'b0),
    .reg_dta_in (32'b0),
    .reg_rd_en  (1'b0),

    .busy       (core_busy),
    .error      (),
    .interrupt  (),
    .watchdog_rst (watchdog_rst),

    .r          (core_r),
    .g          (core_g),
    .b          (core_b),
    .y          (),
    .u          (),
    .v          (),
    .pixel_en   (core_pixel_en),
    .h_sync     (core_h_sync),
    .v_sync     (core_v_sync),
    .c_sync     (),
    .h_pos      (core_h_pos),
    .v_pos      (core_v_pos),

    .mem_req_rd_cmd   (core_mem_cmd),
    .mem_req_rd_addr  (core_mem_addr),
    .mem_req_rd_dta   (core_mem_dta_out),
    .mem_req_rd_en    (core_mem_en),
    .mem_req_rd_valid (core_mem_valid),

    .mem_res_wr_dta          (shim_mem_dta),
    .mem_res_wr_en           (shim_mem_en),
    .mem_res_wr_almost_full  (shim_mem_almost_full),

    .testpoint_dip    (4'b0),
    .testpoint_dip_en (1'b0),
    .init_cnt_out     (core_init_cnt),
    .sync_rst_out     (core_sync_rst),
    .vbw_almost_full_out (core_vbw_almost_full)
);

// =========================================================================
// Memory Shim: 64-bit core <-> 64-bit DDR3
// =========================================================================
mem_shim mem_shim_inst (
    .clk              (clk_mem),
    .rst_n            (reset_n),

    .mem_req_rd_cmd   (core_mem_cmd),
    .mem_req_rd_addr  (core_mem_addr),
    .mem_req_rd_dta   (core_mem_dta_out),
    .mem_req_rd_en    (core_mem_en),
    .mem_req_rd_valid (core_mem_valid),

    .mem_res_wr_dta          (shim_mem_dta),
    .mem_res_wr_en           (shim_mem_en),
    .mem_res_wr_almost_full  (shim_mem_almost_full),

    // DDR3 Avalon-MM Interface
    .ddr3_addr          (DDRAM_ADDR),
    .ddr3_burstcnt      (DDRAM_BURSTCNT),
    .ddr3_read          (DDRAM_RD),
    .ddr3_write         (DDRAM_WE),
    .ddr3_writedata     (DDRAM_DIN),
    .ddr3_byteenable    (DDRAM_BE),
    .ddr3_readdata      (DDRAM_DOUT),
    .ddr3_readdatavalid (DDRAM_DOUT_READY),
    .ddr3_waitrequest   (DDRAM_BUSY),

    .debug_state      (shim_debug_state),
    .debug_sdram_busy (shim_debug_sdram_busy),
    .debug_sdram_ack  (shim_debug_sdram_ack),
    .debug_rd_count   (shim_debug_rd_count),
    .debug_wr_count   (shim_debug_wr_count)
);

// =========================================================================
// Fallback VGA Timing Generator (640x480 @ 60Hz)
// =========================================================================
// The MPEG2 core's syncgen is tied to the decoder pipeline and may not
// produce valid timing until a bitstream is being decoded (syncgen_rst
// stays asserted via the regfile during hard reset). Without valid
// VGA_HS/VGA_VS/VGA_DE, the MiSTer ascal scaler has no input and the
// HDMI transmitter outputs nothing ("Looking for signal").
//
// This fallback generator runs on clk_vid (25.175 MHz)
// and produces standard VGA 640x480 @ 60Hz timing with a white screen.
// Once the core's syncgen starts producing valid vsync edges, we
// switch the output mux to the core's video.
//
// Standard VGA 640x480 @ 60Hz timing (25.175 MHz pixel clock):
//   H: 640 visible, total 800 (HFP=16, HS=96, HBP=48)
//   V: 480 visible, total 525 (VFP=10, VS=2, VBP=33)

reg [9:0] fb_hcnt = 0;  // 0..799
reg [9:0] fb_vcnt = 0;  // 0..524
reg       fb_hs, fb_vs, fb_de;

always @(posedge clk_vid or negedge reset_n) begin
    if (!reset_n) begin
        fb_hcnt <= 0;
        fb_vcnt <= 0;
        fb_hs   <= 1'b0;
        fb_vs   <= 1'b0;
        fb_de   <= 1'b0;
    end else begin
        // Horizontal counter
        if (fb_hcnt == 10'd799) begin
            fb_hcnt <= 0;
            // Vertical counter
            if (fb_vcnt == 10'd524)
                fb_vcnt <= 0;
            else
                fb_vcnt <= fb_vcnt + 1'd1;
        end else begin
            fb_hcnt <= fb_hcnt + 1'd1;
        end

        // Horizontal sync: active high (matching core's syncgen convention)
        // Pixels 656..751
        fb_hs <= (fb_hcnt >= 10'd656 && fb_hcnt <= 10'd751);

        // Vertical sync: active high (matching core's syncgen convention)
        // Lines 490..491
        fb_vs <= (fb_vcnt >= 10'd490 && fb_vcnt <= 10'd491);

        // Display enable: active area 0..639 x 0..479
        fb_de <= (fb_hcnt < 10'd640) && (fb_vcnt < 10'd480);
    end
end

// =========================================================================
// Core Video Active Detection
// =========================================================================
// Detect when the MPEG2 core's syncgen is producing valid video by
// watching for vsync edges. After seeing a few vsync edges, we know
// the core is generating proper timing and can switch to its output.

reg [2:0] core_vs_edge_cnt = 0;
reg       core_vs_prev = 0;
wire      core_video_active = (core_vs_edge_cnt >= 3'd3);

always @(posedge clk_vid or negedge reset_n) begin
    if (!reset_n) begin
        core_vs_edge_cnt <= 0;
        core_vs_prev     <= 0;
    end else begin
        core_vs_prev <= core_v_sync;
        // Count rising edges of core vsync
        if (~core_vs_prev & core_v_sync & ~core_video_active)
            core_vs_edge_cnt <= core_vs_edge_cnt + 1'd1;
    end
end

// =========================================================================
// Video Output Mux
// =========================================================================
// Use the fallback timing generator until the core starts producing
// valid video, then switch to the core's output.

assign VGA_R  = core_video_active ? core_r       : 8'hFF; // Debug: White fallback
assign VGA_G  = core_video_active ? core_g       : 8'hFF; // Debug: White fallback
assign VGA_B  = core_video_active ? core_b       : 8'hFF; // Debug: White fallback
assign VGA_HS = core_video_active ? core_h_sync  : fb_hs;
assign VGA_VS = core_video_active ? core_v_sync  : fb_vs;
assign VGA_DE = core_video_active ? core_pixel_en : fb_de;


uart_debug debug_inst (
    .clk(clk_sys),
    .rst_n(reset_n),
    .tx_pin(UART_TXD),
    .locked(locked),
    .active(core_video_active),
    .arx({1'b0, core_h_pos}),
    .ary({1'b0, core_v_pos}),
    .busy(core_busy),
    .valid(stream_valid),
    // Additional debug signals from mpeg2video core internals
    .init_cnt(core_init_cnt),
    .sync_rst(core_sync_rst),
    .vbw_almost_full(core_vbw_almost_full),
    .mem_req_en(core_mem_en),
    .mem_req_valid(core_mem_valid),
    .mem_res_almost_full(shim_mem_almost_full),
    // DDR3 debug (mapped through mem_shim debug outputs)
    .shim_state(shim_debug_state),          // M: 0=IDLE 1=WR_WAIT 2=RD_WAIT
    .sdram_busy(shim_debug_sdram_busy),     // U: ddr3_waitrequest
    .sdram_ack(shim_debug_sdram_ack),       // K: ddr3 transaction accepted
    // MPG streamer debug
    .streamer_active(streamer_active),
    .streamer_sd_rd(streamer_sd_rd),
    .streamer_sd_ack(streamer_sd_ack),
    .streamer_has_data(streamer_has_data),
    .streamer_file_size(streamer_file_size),
    .streamer_total_sectors(streamer_total_sectors),
    .streamer_next_lba(streamer_next_lba),
    // Memory read/write counters
    .mem_rd_count(shim_debug_rd_count),     // P: DDR3 read completions
    .mem_wr_count(shim_debug_wr_count)      // W: DDR3 write completions
);

assign CLK_SYS = clk_sys;
assign CLK_MEM = clk_mem;

// =========================================================================
// LEDs and Debug
// =========================================================================
assign LED_POWER    = 2'b00; // Let system control
assign LED_DISK     = {streamer_active, stream_valid}; // LED indicates: streaming active, data flowing
assign LOCKED       = locked;

reg [24:0] heartbeat;
always @(posedge clk_sys) heartbeat <= heartbeat + 1'b1;
assign LED_USER     = heartbeat[24]; // Toggle ~1Hz @ 27MHz

// Route UART TX to User IO (Pin 0/1 usually, adapting for standard cable)
// User IO pin mapping usually: [0]=TX, [1]=RX or vice versa depending on cable.
// emu connects to sys_top user_out/user_in.
assign USER_OUT = {6'b0, UART_TXD};

endmodule

