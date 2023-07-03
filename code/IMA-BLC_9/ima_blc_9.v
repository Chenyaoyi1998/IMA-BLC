`timescale 1ns / 1ps
module ima_blc_9#(
    parameter DATA_WIDTH=8,
    parameter BPS_L=1,
    parameter BPN_L=100,
    parameter READ_PIXEL=16,
    parameter BPS_R=BPS_L+BPN_L+READ_PIXEL,
    parameter BPN_R=100
)(
    input clk_p,
    input clk_n,
    input rst_n,
    input i_valid,
    input i_ready,
    input [DATA_WIDTH-1:0] idata,
    output reg o_valid,
    output o_ready,
    output reg [DATA_WIDTH-1:0] odata
    );
    
    wire clk;
    IBUFDS RXD_FPGA_diff (
        .I(clk_p),
        .IB(clk_n),
        .O(clk)
    );
    
    reg [15:0] pixel_cnt_r;
    reg [READ_PIXEL*DATA_WIDTH-1:0] line_buffer_r;
    reg ready_delay_r;
    reg [9*DATA_WIDTH-1:0] black_buffer_r;
    
    reg black_buffer_full_r;
    reg [3:0] black_pixel_cnt_r;
    
    reg [3*DATA_WIDTH-1:0] max_r,med_r,min_r;
    
    reg [2*DATA_WIDTH-1:0] acc_sum;
    reg [7:0] med_cnt_r;
    
    wire sort_mxx_valid;

    reg [3*DATA_WIDTH-1:0] final_sort_r;
    
    reg [DATA_WIDTH-1:0] final_med_r;
    
    reg acc_valid_r1,acc_valid_r2;
    reg ref_en;
    wire ref_valid;
    
    wire [DATA_WIDTH-1:0] ref_data;
    
    wire active_pixel_exist;
    wire black_pixel_exist;
    
    wire ready;
    wire ready_i;
    
    wire sort_valid;
    
    wire [DATA_WIDTH-1:0] max1_w,med1_w,min1_w;
    wire [DATA_WIDTH-1:0] max2_w,med2_w,min2_w;
    wire [DATA_WIDTH-1:0] max3_w,med3_w,min3_w;

    wire [DATA_WIDTH-1:0] maxmin,medmed,minmax;
    
    wire [DATA_WIDTH-1:0] final_med;
    
    wire reset_signal;
    reg o_ready_delay_r;
    reg [4:0] read_pixel_cnt;
    //------------------------------Combination Logic------------------------------//
    assign active_pixel_exist = (pixel_cnt_r >=BPS_L+BPN_L) && (pixel_cnt_r<BPS_R);
    assign black_pixel_exist = ((pixel_cnt_r>=BPS_L) && (pixel_cnt_r<BPS_L+BPN_L)) || ((pixel_cnt_r>=BPS_R) && (pixel_cnt_r<BPS_R+BPN_R));
    
    assign ready=i_ready&(!o_ready);
    assign ready_i = ready&(!ready_delay_r);
    
    assign sort_valid = black_buffer_full_r;
    
    comparator_w  #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_comparator1(
        .data_befor    (black_buffer_r[3*DATA_WIDTH-1:0]),
        .max              (max1_w),
        .med              (med1_w),
        .min               (min1_w)
    );
    comparator_w  #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_comparator2(
        .data_befor    (black_buffer_r[6*DATA_WIDTH-1:3*DATA_WIDTH]),
        .max              (max2_w),
        .med              (med2_w),
        .min               (min2_w)
    );
    comparator_w  #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_comparator3(
        .data_befor    (black_buffer_r[9*DATA_WIDTH-1:6*DATA_WIDTH]),
        .max              (max3_w),
        .med              (med3_w),
        .min              (min3_w)
    );
    
    max u_minmax(
        .data(min_r),
        .max(minmax)
    );
    med_w u_medmed(
        .data(med_r),
        .med(medmed)
    );
    min u_maxmin(
        .data(max_r),
        .min(maxmin)
    );
    
    med_w u_fianal_med(
        .data(final_sort_r),
        .med(final_med)
    );
    
    assign reset_signal = o_ready & (!o_ready_delay_r);
    
    assign o_ready = read_pixel_cnt == 0;
    //------------------------------Timing Logic------------------------------//
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            ready_delay_r <= 1'b0;
        else
            ready_delay_r <= ready;
    end
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            pixel_cnt_r <= 'd0;
        else if(pixel_cnt_r == 1 + BPN_L + READ_PIXEL + BPN_R && i_valid)
            pixel_cnt_r <= 'd0;
        else if(i_valid)
            pixel_cnt_r <= pixel_cnt_r + 1;
    end
    
    always@(posedge clk  or negedge rst_n)begin
        if(!rst_n)
            line_buffer_r <= 'd0;
        else if(i_valid && active_pixel_exist)
            line_buffer_r <= {line_buffer_r[(READ_PIXEL-1)*DATA_WIDTH-1:0],idata};
        else if(ready_i&&(!o_ready))
            line_buffer_r <= line_buffer_r<<DATA_WIDTH;
    end
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            black_pixel_cnt_r <= 'd0;
        else if(black_pixel_cnt_r == 'd2 && i_valid)
            black_pixel_cnt_r <= 'd0;
        else if(i_valid && black_pixel_exist)
            black_pixel_cnt_r <= black_pixel_cnt_r + 1;
    end

    //black_buffer
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            black_buffer_r <= 'd0;
            black_buffer_full_r <= 1'b0;end
        else if(i_valid && black_pixel_exist)begin
            black_buffer_r <= {black_buffer_r[8*DATA_WIDTH-1:0],idata};
            black_buffer_full_r <= black_pixel_cnt_r == 2'd2;end
        else begin
            black_buffer_r <= black_buffer_r;
            black_buffer_full_r <= 1'b0;end
    end
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            {max_r,med_r,min_r} <= 'd0;
        end
        else if(sort_valid)begin
            max_r <= {max1_w,max2_w,max3_w};
            med_r <= {med1_w,med2_w,med3_w};
            min_r <= {min1_w,min2_w,min3_w};
        end
    end
    
    sort_mxx u_sort_mxx(
         .clk             (clk),
         .rst_n          (rst_n),
         .sort_valid    (sort_valid),
         .pixel_cnt     (pixel_cnt_r),
         .o_valid        (sort_mxx_valid)
    );
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            final_sort_r <= 'd0;
        else if(sort_mxx_valid)
            final_sort_r <= {minmax,medmed,maxmin};
    end
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            final_med_r <= 'd0;
            {acc_valid_r1,acc_valid_r2,ref_en} <= 3'b0;end
        else begin
            final_med_r <= final_med;
            {acc_valid_r1,acc_valid_r2,ref_en} <= {sort_mxx_valid,acc_valid_r1,acc_valid_r2};end
    end

    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            acc_sum <= 'd0;
            med_cnt_r <= 'd0;end
        else if(reset_signal)begin//TODO
            acc_sum <= 'd0;
            med_cnt_r <= 'd0;end
        else if(acc_valid_r2)begin
            acc_sum <= acc_sum + final_med_r;
            med_cnt_r <= med_cnt_r + 1;end
    end

    divider #(
        .N(2*DATA_WIDTH),
        .M(8),
        .O((BPN_L + BPN_R - 6) / 3)
    )u_divider(
        .clk(clk),
        .rstn(rst_n),
        .data_rdy(ref_en),
        .dividend(acc_sum),
        .divisor(med_cnt_r),
        .res_o(ref_valid),
        .merchant(ref_data)
    );
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            o_ready_delay_r <= 1'b0;
        else
            o_ready_delay_r <= o_ready;
    end
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            read_pixel_cnt <= 'd0;
        else if(read_pixel_cnt == READ_PIXEL+1)
            read_pixel_cnt <= 1'b0;
        else if(read_pixel_cnt > 0 && ready_i)
            read_pixel_cnt <= read_pixel_cnt + 1;
        else if(ref_valid)
            read_pixel_cnt <= 1'b1;
    end
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            odata <= 'd0;
            o_valid <= 1'b0;
        end
        else if(ready_i&&(!o_ready))begin
            odata <= line_buffer_r[READ_PIXEL*DATA_WIDTH-1:(READ_PIXEL-1)*DATA_WIDTH] - ref_data;
            o_valid <= 1'b1;
        end
        else
            o_valid <= 1'b0;
    end
endmodule
