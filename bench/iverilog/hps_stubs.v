module cyclonev_hps_interface_mpu_general_purpose (
    input [31:0] gp_in,
    output reg [31:0] gp_out
);
    initial gp_out = 0;
endmodule

module cyclonev_hps_interface_peripheral_uart (
    input ri,
    input dsr,
    input dcd,
    output dtr,
    input cts,
    output rts,
    input rxd,
    output txd
);
    assign dtr = 0;
    assign rts = 0;
    assign txd = 1;
endmodule

module cyclonev_hps_interface_interrupts (
    input [63:0] irq
);
endmodule

// Stub for hps_io to avoid compiling the full system file
module hps_io #(
    parameter CONF_STR = "",
    parameter WIDE = 0,
    parameter VDNUM = 1,
    parameter PS2DIV = 1000
) (
    input clk_sys,
    inout [48:0] HPS_BUS,

    input ioctl_download,
    input ioctl_wr,
    input [26:0] ioctl_addr,
    input [7:0] ioctl_dout,
    input [15:0] ioctl_index,
    output reg ioctl_wait,

    input [1:0] buttons,
    output reg [31:0] status,
    output reg [31:0] joystick_0,

    output reg forced_scandoubler,
    output reg [21:0] gamma_bus,
    output reg direct_video,

    input [31:0] sd_lba,
    input [5:0] sd_blk_cnt,
    input sd_rd,
    input sd_wr,
    output reg sd_ack,
    input [13:0] sd_buff_addr,
    output reg [7:0] sd_buff_dout,
    input [7:0] sd_buff_din,
    input sd_buff_wr,

    output reg img_mounted,
    output reg img_readonly,
    output reg [63:0] img_size
);
    // Initialize outputs
    initial begin
        status = 0;
        joystick_0 = 0;
        direct_video = 0;
        sd_ack = 0;
        sd_buff_dout = 0;
        img_mounted = 0;
        img_size = 0;
        ioctl_wait = 0;
    end
endmodule
