module LCD_DMD_driver(

	clock_50,

	dotClock,				//Rising edge pulse that data comes in on
	dotData,					//Dots coming in from video processor
	dotLatch,				//Active high pulse that loads frame onto display
	dotReg,					//Select which register to write to
	dotEnable,
	
	pairECLK,
	pairE2,
	pairE1,
	pairE0,	
	
	pairOCLK,
	pairO2,
	pairO1,
	pairO0,

	led0,
	
	backlight_pwm
	
);

//IO defines

output led0;

input clock_50;

input dotClock;
input dotData;
input dotLatch;
input [2:0] dotReg;
input dotEnable;

output pairOCLK;
output pairO2;
output pairO1;
output pairO0;

output pairECLK;
output pairE2;
output pairE1;
output pairE0;

output backlight_pwm;

//Registers for internal logic use

reg [3:0] which_bit = 6;

reg dataEnable = 1'b0;
reg vsync = 1'b0;
reg hsync = 1'b0;

reg [5:0] redE = 0;
reg [5:0] greenE = 0;
reg [5:0] blueE = 0;

reg [5:0] redO = 0;
reg [5:0] greenO = 0;
reg [5:0] blueO = 0;

reg [6:0] CLKEdata = 7'b1100011;
reg [6:0] RX2Edata = 7'b0000000;
reg [6:0] RX1Edata = 7'b0000000;
reg [6:0] RX0Edata = 7'b0000000;

reg [6:0] CLKOdata = 7'b1100011;
reg [6:0] RX2Odata = 7'b0000000;
reg [6:0] RX1Odata = 7'b0000000;
reg [6:0] RX0Odata = 7'b0000000;

reg [3:0] byteBitIn = 7;
reg [7:0] byteBuild = 0;

reg [15:0] vCurrent = 0;				//Which line we're currently on

parameter [15:0] vFront = 19;			//If current V line is more than this, it's not a Vertical Front Porch signal
parameter [15:0] vBack = 1104;		//If current V line is more than this, it's not a Vertical Back Porch signal		
parameter [15:0] vTotal = 1111;		//If current V line equals this, frame done!

reg [15:0] hCurrent = 0;				//Current horizontal position

parameter hFront = 45; // 25;					//If current H is more than this, it's not a Horizontal Front Porch signal  //21
parameter hBack = hFront + 961;		//If current H is less than this, it's not a Horizontal Back Porch signal	 //34
parameter hSync = hBack + 35;			//If current H is more than this, it's the Horizontal Sync Signal
parameter hTotal = hSync + 16;		//If current H equals this, line done!

parameter [15:0] leftSide = hFront + 32;			//Left and right fat pixel borders
parameter [15:0] rightSide = leftSide + 897;

reg [15:0] currentPixel = 0;			//Which 4x4 pixel we are drawing
reg [7:0] pixelX = 0;					//Which sub-pixel of a fat pixel we are drawing
reg [7:0] pixelY = 0;					
reg [15:0] pixelYcount = 0;

reg [15:0] startingRaster = 0;		//Where the display should start reading raster memory from

reg [3:0] shaderX [0:13] [0:13];

reg [5:0] shaderZ [0:13] [0:13];

reg [3:0] shader [0:44] [0:29];
reg [7:0] pwmBrightness = 200;		
reg [5:0] lightBar;

reg [15:0] settings [0:15];			//Stores 16 word-sized settings used to config the FPGA via external MCU
reg [7:0] whichSetting = 255;			//Which setting we are getting via SPI
reg hiLow = 1'b0;							//Which byte we are getting for the setting (0 = high byte, 1 = low byte

reg hFlag = 0;
reg vFlag = 0;

reg dmdFlag = 0;

always @*
begin

	  //Even
	  
	  RX2Edata[6] <= dataEnable;
	  RX2Edata[5] <= vsync;
	  RX2Edata[4] <= hsync;	  
	  RX2Edata[3:0] <= blueE[5:2];
	  
	  RX1Edata[6:5] <= blueE[1:0];
	  RX1Edata[4:0] <= greenE[5:1];
	  
	  //RX0Edata[0] <= greenE[0];
	  RX0Edata[5:0] <= redE[5:0];	  

	  //Odd

	  RX2Odata[6] <= dataEnable;
	  RX2Odata[5] <= vsync;
	  RX2Odata[4] <= hsync;	  
	  RX2Odata[3:0] <= blueO[5:2];	
	  
	  RX1Odata[6:5] <= blueO[1:0];
	  RX1Odata[4:0] <= greenO[5:1];
	  
	  //RX0Odata[0] <= greenO[0];
	  RX0Odata[5:0] <= redO[5:0];
	 
end

always @(posedge bit_clock_out)									//The master clock
begin

	readAddress <= currentPixel;											//Set RAM read port to current pixel

	case(which_bit)
	
		0		  :	begin
							which_bit <= 6;													//Reset bit counter
							hFlag <= 1;				
						end
		default :	begin
							which_bit <= which_bit - 4'h1;							   //If not done drawing a pixel, move to the next bit
							hFlag <= 0;		
						end
	
	endcase
		
end		
		

always @(posedge hFlag)
begin

	case(hCurrent)
		hTotal :		begin
							hCurrent <= 0;														//Set H counter to 0
							case(vCurrent)							
								vTotal	:	begin
													vCurrent <= 0;												//Set V counter to 0
													pixelY <= 0;
													pixelX <= 0;												//Reset this one too, just in case
													currentPixel <= startingRaster;						//Might as well reset this too PUT IN JUMP VECTOR LATER
													pixelYcount <= 0;								
												end
								default	:	begin
													vCurrent <= vCurrent + 16'h1;									//If not at end of frame, jump to next line													
													if (vCurrent >= (settings[1] + vFront))					//Only advance pixels if we're past the starting line for the DMD image					
														begin
															if (pixelY == 13)																	//Did we draw all 14 lines of the pixel?
																begin
																	pixelY <= 0;																//Reset the pixelY counter
																	pixelYcount <= pixelYcount + 16'h1;										//Increment the total pixel counter (how many virtual DMD lines we've drawn vertically)
																end
															else
																begin
																	pixelY <= pixelY + 8'h1;													//Increment pixel line counter										
																	currentPixel <= currentPixel - 16'h80;									//Go back 128 bytes in memory so we draw the same color pixels over again										
																end	
														end									
												end
							endcase
						end
		default : 	begin		
							hCurrent <= hCurrent + 16'h1;																		//Increment H counter

							if (dataEnable)
								begin
									if (vCurrent < (settings[0] + vFront))								//White top portion? All white pixels (no shapes) We don't care															
										begin
											redO[5:0] <= lightBar[5:0];
											greenO[5:0] <= lightBar[5:0];
											blueO[5:0] <= lightBar[5:0];					
												
											redE[5:0] <= lightBar[5:0];
											greenE[5:0] <= lightBar[5:0];
											blueE[5:0] <= lightBar[5:0];					//lightBarBO[5:0]; //62;				//settings[6]; //							
										end
									else																												//Below white portion. Will either be black, or active DMD area

										begin
											if (vCurrent >= (settings[1] + vFront) && dmdFlag && pixelYcount < settings[5])															//Only draw if active pixel area (not in horizontal front or back porch)		
												begin	
													if (pixelX == 12)
														begin		
															if (pixelYcount < settings[5])
																begin
																	currentPixel <= currentPixel + 16'h1;
																end
															pixelX <= 0;							
														end
													else
														begin
															pixelX <= pixelX + 8'h2;		
														end	
																									
													redO[5:0] <= dataOut[7:5] * shaderX[pixelY][pixelX][3:0];
													greenO[5:0] <= dataOut[4:2] * shaderX[pixelY][pixelX][3:0];
													blueO[5:0] <= (dataOut[1:0] << 1) * shaderX[pixelY][pixelX][3:0];
													
													redE[5:0] <= dataOut[7:5] * shaderX[pixelY][pixelX + 1][3:0];
													greenE[5:0] <= dataOut[4:2] * shaderX[pixelY][pixelX + 1][3:0];
													blueE[5:0] <= (dataOut[1:0] << 1) * shaderX[pixelY][pixelX + 1][3:0];													
																								
												end
											else
												begin
													redO <= 0;
													greenO <= 0;
													blueO <= 0;								
														
													redE <= 0;
													greenE <= 0;
													blueE <= 0;				
												end					
										end	

						
										end
							else
								begin
									redO <= 0;
									greenO <= 0;
									blueO <= 0;								
										
									redE <= 0;
									greenE <= 0;
									blueE <= 0;					
								end	

						end
	endcase
		
	if ((hCurrent > hFront && hCurrent < hBack) && (vCurrent > vFront && vCurrent < vBack))						//Data is only enabled during visible pixels - disabled in H and V porches
		begin
			dataEnable <= 1'b1;
		end
		else
		begin
			dataEnable <= 1'b0;
		end		

	if ((hCurrent > leftSide && hCurrent < rightSide))						
		begin
			dmdFlag <= 1'b1;
		end
		else
		begin
			dmdFlag <= 1'b0;
		end		

		
	case(hCurrent)
	
		0		  :	begin
							hsync <= 1'b1;		
						end
		hSync	  :	begin
							hsync <= 1'b0;	
						end	
	endcase
	
	case(vCurrent)
		0       :	begin
							vsync <= 1'b1;
						end	
		1107	  :	begin
							vsync <= 1'b0;	
						end												
	endcase		
			
end



always @(posedge dotClock)
begin

	case(dotLatch)
	
		0			:	begin
		
							case(byteBitIn)
							
								7			:	begin
													if (dotReg[0] == 0)
														begin
															writeAddress <=  writeAddress + 16'h1;	
														end
													else
														begin
															if (hiLow == 0)
																begin
																	whichSetting <= whichSetting + 8'h1;
																end						
														end										
												end										
								default	:	begin
													writeAddress <=  writeAddress;  								
												end
							endcase
							
							byteBuild[byteBitIn] <= dotData;		
							
						end
		default	:	begin
							byteBuild[7:0] <= 0;
							whichSetting <= 255;									//Always reset this too

							case(startingRaster)
							
								0			:	begin
													startingRaster <= 8192;						//Where the display should draw from
													writeAddress <= 65535;						//Where the next frame will be read into memory. We goto the last position of the 16 bit memory counter so it rolls forward to 0 on next cycle											
												end
								default	:	begin
													startingRaster <= 0;							//Where the display should draw from
													writeAddress <= 8191;						//Where the next frame will be read into memory. We ONE BELOW the target since next cycle it will be advanced before anything happens										
												end
												
							endcase
							
	
						end
	endcase
	
end


always @(negedge dotClock)
begin

	if (dotLatch == 0)											//Clocking in data?
		begin
			if (byteBitIn == 0)									//That was the last bit?
				begin
					
					if (dotReg[0] == 0)
						begin
							writeEnable <= 1; 
							dataIn[7:0] <= byteBuild[7:0];
						end
					else												//Register write?
						begin
							if (hiLow == 0)
								begin
									settings[whichSetting][15:8] <= byteBuild[7:0];
								end
							else
								begin
									settings[whichSetting][7:0] <= byteBuild[7:0];
								end	
							hiLow <= hiLow + 1'b1;					//Toggle hi low							
						end

					byteBitIn <= 7;

				end
			else
				begin                  
					byteBitIn <= byteBitIn - 4'h1;                                                      
				end								
		end
	else																//Data latch is ACTIVE HIGH
		begin	
			hiLow <= 0;
			writeEnable <= 0; 		
			byteBitIn <= 7;				
		end		
	
end


always @(posedge pwm_clock_out)
begin

		led0 <= 1;

		if (pwmBrightness > settings[3])
			begin
				backlight_pwm <= 0;
			end
		else
			begin
				backlight_pwm <= 1;			
			end		

		if (pwmBrightness == 250)
			begin
				pwmBrightness <= 0;
			end
		else
			begin
				pwmBrightness <= pwmBrightness + 8'h1;			
			end				
			
end


assign pairOCLK =        CLKOdata[which_bit];
assign pairO2 =          RX2Odata[which_bit];
assign pairO1 =          RX1Odata[which_bit];
assign pairO0 =          RX0Odata[which_bit];

assign pairECLK =        CLKEdata[which_bit];
assign pairE2 =          RX2Edata[which_bit];
assign pairE1 =          RX1Edata[which_bit];
assign pairE0 =          RX0Edata[which_bit];

assign lightBar[5:0] =   settings[6][5:0];

clocks u1 (

	.inclk0(clock_50),
	.c0(bit_clock_out),
	.c1(pwm_clock_out)
	
	);	
	
ram u2 (

	.data(dataIn),
	.rdaddress(readAddress),
	.rdclock(bit_clock_out),
	.wraddress(writeAddress),
	.wrclock(dotClock),
	.wren(writeEnable),
	.q(dataOut)
	);	
	
reg	[7:0]   dataIn;
reg	[15:0]  readAddress;
reg	[15:0]  writeAddress;
reg	writeEnable = 0;
wire	[7:0]  dataOut;
	
initial
begin

	//End of white bar, start of DMD, brightness (125-225), wide pixels, tall pixels, white bar brightness (20-62),
	
	//settings[0:15] = '{250, 460, 0, 225, 128, 32, 62, 0, 0, 0, 0, 0, 0, 0, 0, 0};				//RZ default
	
	//settings[0:15] = '{250, 460, 0, 225, 128, 32, 62, 0, 0, 0, 0, 0, 0, 0, 0, 0};
	
	settings[0:15] = '{50, 100, 0, 225, 128, 64, 62, 0, 0, 0, 0, 0, 0, 0, 0, 0};				//Double-high default
	
	//0 = endingWhite bar
	//1 = start of DMD draw
	//2 = pixel shape
	//3 = brightness (0-250)
	//4 = width in virtual pixels (just 128 for now)
	//5 = height in virtual pixels (32 or 64)

	shaderX = 
	'{

	'{0, 0, 0, 0, 5, 5, 5, 5, 5, 0, 0, 0, 0, 0},		
	'{0, 0, 5, 5, 9, 9, 9, 9, 9, 5, 5, 0, 0, 0},
	'{0, 5, 9, 9, 9, 9, 9, 9, 9, 9, 9, 5, 0, 0},
	'{0, 5, 9, 9, 9, 9, 9, 9, 9, 9, 9, 5, 0, 0},
	'{5, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 5, 0},	
	'{5, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 5, 0},		
	'{5, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 5, 0},
	
	'{5, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 5, 0},		
	'{5, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 5, 0},
	'{0, 5, 9, 9, 9, 9, 9, 9, 9, 9, 9, 5, 0, 0},
	'{0, 5, 9, 9, 9, 9, 9, 9, 9, 9, 9, 5, 0, 0},
	'{0, 0, 5, 5, 9, 9, 9, 9, 9, 5, 5, 0, 0, 0},	
	'{0, 0, 0, 0, 5, 5, 5, 5, 5, 0, 0, 0, 0, 0},		
	'{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}	

	};	
		
	shader = 
	'{

	//Round Circle, Shaded Edges
	
	'{4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0,		 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0},
	'{4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0,		 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0,		 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0},
	'{4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0,		 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0},	
	
	//Shaded Tiles
	
	'{4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0,		 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0,		 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0},		
	
	//Fake High Resolution		

	'{4'h0, 4'h2, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h5, 4'h2, 4'h0, 4'h0,		 4'h0, 4'h2, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h5, 4'h2, 4'h0, 4'h0},		
	'{4'h2, 4'h5, 4'h9, 4'h9, 4'h9, 4'h5, 4'h3, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h5, 4'h2, 4'h0,		 4'h2, 4'h5, 4'h9, 4'h9, 4'h9, 4'h5, 4'h3, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h5, 4'h2, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h3, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h3, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h3, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h3, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h3, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h3, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},	
	'{4'h3, 4'h5, 4'h5, 4'h5, 4'h5, 4'h3, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0,		 4'h3, 4'h5, 4'h5, 4'h5, 4'h5, 4'h3, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0},
	'{4'h0, 4'h3, 4'h3, 4'h3, 4'h3, 4'h0, 4'h0, 4'h0, 4'h0, 4'h2, 4'h2, 4'h2, 4'h2, 4'h0, 4'h0,		 4'h0, 4'h3, 4'h3, 4'h3, 4'h3, 4'h0, 4'h0, 4'h0, 4'h0, 4'h3, 4'h3, 4'h3, 4'h3, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0},

	'{4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0,		 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0},		
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h3, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h3, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h3, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h3, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},
	'{4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h3, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0,		 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h3, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h9, 4'h5, 4'h0},	
	'{4'h2, 4'h5, 4'h9, 4'h9, 4'h9, 4'h5, 4'h3, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h5, 4'h2, 4'h0,		 4'h2, 4'h5, 4'h9, 4'h9, 4'h9, 4'h5, 4'h3, 4'h0, 4'h5, 4'h9, 4'h9, 4'h9, 4'h5, 4'h2, 4'h0},
	'{4'h0, 4'h2, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h5, 4'h2, 4'h0, 4'h0,		 4'h0, 4'h2, 4'h5, 4'h5, 4'h5, 4'h0, 4'h0, 4'h0, 4'h0, 4'h5, 4'h5, 4'h5, 4'h2, 4'h0, 4'h0},
	'{4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0,		 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0, 4'h0}

	};


end	
	
	
endmodule
