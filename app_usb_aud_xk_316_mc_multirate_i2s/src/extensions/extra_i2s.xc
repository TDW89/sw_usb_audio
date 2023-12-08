#include <platform.h>
#include <xs1.h>
#include <print.h>
#include <stdlib.h>
#include <string.h>
#include "i2s.h"
#include "src.h"
#include "xua.h"

/* TODO

- General
    - Seperate recording and playback SRC related defines

- Optimise:
    - Optimise for 192kHz operation

- Buffering:
    - Only push to fifo when "locked"

*/


#ifndef USE_ASRC
#define USE_ASRC (0)
#endif

#ifndef EXTRA_I2S_CHAN_COUNT_IN
#define EXTRA_I2S_CHAN_COUNT_IN  (2)
#endif

#ifndef EXTRA_I2S_CHAN_INDEX_IN
#define EXTRA_I2S_CHAN_INDEX_IN  (0)
#endif

#ifndef EXTRA_I2S_CHAN_COUNT_OUT
#define EXTRA_I2S_CHAN_COUNT_OUT (2)
#endif

#ifndef EXTRA_I2S_CHAN_INDEX_OUT
#define EXTRA_I2S_CHAN_INDEX_OUT (0)
#endif

#define DATA_BITS                (32)
#define SAMPLE_FREQUENCY         (48000)

void exit(int);

unsafe chanend uc_i2s;

/* Note, re-using I2S data lines on MC audio board for LR and Bit clocks */

on tile[1]: out buffered port:32 p_i2s_dout[1] = {PORT_I2S_DAC1};
on tile[1]: in buffered port:32 p_i2s_din[1] =   {PORT_SPDIF_OUT};
on tile[1]: in port p_i2s_bclk =                 PORT_I2S_DAC2;
on tile[1]: in buffered port:32 p_i2s_lrclk =    PORT_I2S_DAC3;
on tile[1]: in port p_off_bclk =                 XS1_PORT_16A;
on tile[1]: clock clk_bclk =                     XS1_CLKBLK_1;

extern in port p_mclk_in;

/* TODO all these defines are shared between playback and record streams - this should be fixed */

#define     SRC_N_CHANNELS                (2)   // Total number of audio channels to be processed by SRC (minimum 1)
#define     SRC_N_INSTANCES               (2)   // Number of instances (each usually run a logical core) used to process audio (minimum 1)
#define     SRC_CHANNELS_PER_INSTANCE     (SRC_N_CHANNELS/SRC_N_INSTANCES) // Calculated number of audio channels processed by each core
#define     SRC_N_IN_SAMPLES              (4)   // Number of samples per channel in each block passed into SRC each call
                                                // Must be a power of 2 and minimum value is 4 (due to two /2 decimation stages)
#define     SRC_N_OUT_IN_RATIO_MAX        (5)   // Max ratio between samples out:in per processing step (44.1->192 is worst case)
#define     SRC_DITHER_SETTING            (0)   // Enables or disables quantisation of output with dithering to 24b
#define     SRC_MAX_NUM_SAMPS_OUT         (SRC_N_OUT_IN_RATIO_MAX * SRC_N_IN_SAMPLES)
#define     SRC_OUT_BUFF_SIZE             (SRC_CHANNELS_PER_INSTANCE * SRC_MAX_NUM_SAMPS_OUT) // Size of output buffer for SRC for each instance
#define     SRC_OUT_FIFO_SIZE             (SRC_N_CHANNELS * SRC_MAX_NUM_SAMPS_OUT * 4)        // Size of output FIFO for SRC

/* Stuff that must be defined for lib_src */
#define SSRC_N_IN_SAMPLES                 (SRC_N_IN_SAMPLES) /* Used by SRC_STACK_LENGTH_MULT in src_mrhf_ssrc.h */
#define ASRC_N_IN_SAMPLES                 (SRC_N_IN_SAMPLES) /* Used by SRC_STACK_LENGTH_MULT in src_mrhf_asrc.h */

#define SSRC_N_CHANNELS                   (SRC_CHANNELS_PER_INSTANCE) /* Used by SRC_STACK_LENGTH_MULT in src_mrhf_ssrc.h */
#define ASRC_N_CHANNELS                   (SRC_CHANNELS_PER_INSTANCE) /* Used by SRC_STACK_LENGTH_MULT in src_mrhf_asrc.h */

typedef struct fifo_f
{
    unsigned wrPtr;
    unsigned rdPtr;
    int size;
    int fill;
    int inUnderflow;
} fifo_t;

static void init_fifo(fifo_t &f, int array[size], unsigned size)
{
    f.wrPtr = 0;
    f.rdPtr = 0;
    f.size = size;
    f.fill = 0;
    f.inUnderflow = 1;

    unsafe
    {
        int * unsafe arrayPtr = &array[0];
        memset(arrayPtr, 0xffffffff, size * (sizeof(array[0])));
    }
}

/* TODO check we don't have a channel swap issue on exiting overflow/underflow */
#pragma unsafe arrays
static inline unsigned fifo_pop(fifo_t &f, int array[], int &sample)
{
    if (f.inUnderflow)
    {
        if(f.fill > (f.size/2))
        {
            /* Exit underflow */
            f.inUnderflow = 0;
        }
        else
        {
            sample = 0;
            return 1;
        }
    }

    sample = array[f.rdPtr];

    f.fill--;

    /* Check if entering underflow */
    f.inUnderflow = (f.fill == 0);

    f.rdPtr++;
    if(f.rdPtr == SRC_OUT_FIFO_SIZE)
        f.rdPtr = 0;

    return 0;
}

#pragma unsafe arrays
static inline void fifo_push(fifo_t &f, int array[], const int sample)
{
    /* Check for FIFO full */
    if(f.fill >= f.size)
    {
        f.rdPtr = (f.wrPtr + (f.size/2)) % f.size;
        f.fill = f.size/2;
    }
    array[f.wrPtr] = sample;
    f.fill++;
    f.wrPtr++;
    if(f.wrPtr == SRC_OUT_FIFO_SIZE)
        f.wrPtr = 0;
}

int g_usbSamFreq = DEFAULT_FREQ;

void UserBufferManagementInit(unsigned samFreq)
{
    /* Check for sample-rate change */
    if(g_usbSamFreq != samFreq)
    {
        g_usbSamFreq = samFreq;

        unsafe
        {
            outuint((chanend) uc_i2s, 1);
            outuint((chanend) uc_i2s, g_usbSamFreq);
            outct((chanend) uc_i2s, XS1_CT_END);
        }
    }
}

#pragma unsafe arrays
void UserBufferManagement(unsigned sampsFromUsbToAudio[], unsigned sampsFromAudioToUsb[])
{
    unsafe
    {
        outuint((chanend) uc_i2s, 0);

        for(size_t i = 0; i < EXTRA_I2S_CHAN_COUNT_OUT; i++)
        {
            outuint((chanend)uc_i2s, sampsFromUsbToAudio[i + EXTRA_I2S_CHAN_INDEX_OUT]);
        }
        outct((chanend)uc_i2s, XS1_CT_END);

        for(size_t i = 0; i< EXTRA_I2S_CHAN_COUNT_IN; i++)
        {
            sampsFromAudioToUsb[i + EXTRA_I2S_CHAN_INDEX_IN] = inuint((chanend) uc_i2s);
        }
        chkct((chanend)uc_i2s, XS1_CT_END);
    }
}

#pragma unsafe arrays
static inline int trigger_src(streaming chanend c_src[SRC_N_INSTANCES],
                                int srcInputBuff[SRC_N_INSTANCES][SRC_N_IN_SAMPLES][SRC_CHANNELS_PER_INSTANCE],
                                fifo_t &fifo,
                                int srcOutputBuff[SRC_OUT_FIFO_SIZE], uint64_t fsRatio)
{

    int nSamps = 0;
#pragma loop unroll
    for (int i=0; i<SRC_N_INSTANCES; i++)
    {
        c_src[i] <: (uint64_t) fsRatio;

#pragma loop unroll
        for (int j=0; j<SRC_N_IN_SAMPLES; j++)
        {
#pragma loop unroll
            for (int k=0; k<SRC_CHANNELS_PER_INSTANCE; k++)
            {
                c_src[i] <: srcInputBuff[i][j][k];
            }
        }
    }

    /* Get number of samples to receive from all SRC cores */
    /* Note, all nSamps should be equal */
#pragma loop unroll
    for (int i=0; i < SRC_N_INSTANCES; i++)
    {
        c_src[i] :> nSamps;
    }

    for (int j=0; j < nSamps; j++)
    {
#pragma loop unroll
        for (int k=0; k<SRC_CHANNELS_PER_INSTANCE; k++)
        {
            int sample;
#pragma loop unroll
            for (int i=0; i<SRC_N_INSTANCES; i++)
            {
                c_src[i] :> sample;
                fifo_push(fifo, srcOutputBuff, sample);
            }
        }
    }

    return nSamps;
}

#ifndef LOG_CONTROLLER
#define LOG_CONTROLLER (0)
#endif

#if LOG_CONTROLLER
#define CONT_LOG_SIZE      (4000)
#define CONT_LOG_SUBSAMPLE (100)
int e[CONT_LOG_SIZE];
int f_p[CONT_LOG_SIZE];
int f_r[CONT_LOG_SIZE];
float r_p[CONT_LOG_SIZE];
float r_r[CONT_LOG_SIZE];
int sr[CONT_LOG_SIZE];
int logCounter = 0;
int logCounterSub = 0;
#endif



#pragma unsafe arrays
int i2s_data(server i2s_frame_callback_if i_i2s, chanend c, streaming chanend c_src_play[SRC_N_INSTANCES], streaming chanend c_src_rec[SRC_N_INSTANCES], int samFreq)
{
    unsigned srChange = 0;

    int srcInputBuff_play[SRC_N_INSTANCES][SRC_N_IN_SAMPLES][SRC_CHANNELS_PER_INSTANCE];
    int srcInputBuff_rec[SRC_N_INSTANCES][SRC_N_IN_SAMPLES][SRC_CHANNELS_PER_INSTANCE];

    int srcOutputBuff_play[SRC_OUT_FIFO_SIZE];
    int srcOutputBuff_rec[SRC_OUT_FIFO_SIZE];

    int sampleIdx_play = 0;
    int sampleIdx_rec = 0;

    fifo_t fifo_play;
    fifo_t fifo_rec;
int logCounterSub = 0;
int logCounterSub = 0;
int logCounterSub = 0;
int logCounterSub = 0;
int logCounterSub = 0;

    int usbCounter = 0;

    float floatRatio_play = (float) samFreq/SAMPLE_FREQUENCY;
    float floatRatio_rec = (float) SAMPLE_FREQUENCY/samFreq;

    float idealFloatRatio_play = floatRatio_play;
    float idealFloatRatio_rec = floatRatio_rec;

    /* Q60 representations of the above */
    uint64_t fsRatio = (uint64_t) floatRatio_play * (1LL << 60);
    uint64_t fsRatio_rec = (uint64_t) floatRatio_rec * (1LL << 60);

    unsigned short lastPt = 0;

    int asrcCounter_play = 0;
    int asrcCounter_rec = 0;

    int phaseError = 0;
    int phaseErrorInt = 0;

    int shutdown = 0;
    int shutdownI2s = 0;

    init_fifo(fifo_play, srcOutputBuff_play, sizeof(srcOutputBuff_play)/sizeof(srcOutputBuff_play[0]));
    init_fifo(fifo_rec, srcOutputBuff_rec, sizeof(srcOutputBuff_rec)/sizeof(srcOutputBuff_rec[0]));

    int samplesToGo[EXTRA_I2S_CHAN_COUNT_IN];
    while (!shutdown)
    {
        select
        {
            case inuint_byref(c, srChange):

                if(srChange)
                {
                    samFreq = inuint(c);
                    inct(c);
                    shutdownI2s = 1;
                }
                else
                {
                    /* Receive samples from USB audio (other side of the UserBufferManagement() comms) */
#pragma loop unroll
                    for(size_t i = 0; i< EXTRA_I2S_CHAN_COUNT_OUT; i++)
                    {
                        srcInputBuff_play[i/SRC_CHANNELS_PER_INSTANCE][sampleIdx_play][i % SRC_CHANNELS_PER_INSTANCE] = inuint(c);
                    }
                    chkct(c, XS1_CT_END);

                    /* Send samples to USB audio (other side of the UserBufferManagement() comms */
#pragma loop unroll
                    for(size_t i = 0; i< EXTRA_I2S_CHAN_COUNT_IN; i++)
                    {
                        outuint(c, samplesToGo[i]);
                    }

                    outct(c, XS1_CT_END);

                    for(size_t i = 0; i< EXTRA_I2S_CHAN_COUNT_IN; i++)
                    {
                        int sample;
                        int error = fifo_pop(fifo_rec, srcOutputBuff_rec, sample);
                        samplesToGo[i] = sample;
                    }

                    sampleIdx_play++;

                    if(sampleIdx_play == SRC_N_IN_SAMPLES)
                    {
                        sampleIdx_play = 0;

                        usbCounter++;

                        /* Run the control loop approx sample frequency independant of primary sample rate */
                        if(usbCounter >= ((25 * (samFreq/SAMPLE_FREQUENCY))+1))
                        {
                            usbCounter = 0;

                            unsigned short pt;
                            asm volatile(" getts %0, res[%1]" : "=r" (pt) : "r" (p_off_bclk));

                            /* The actual number of bit clocks on the output i2s */
                            int measuredClocks;

                            if (porttimeafter(pt, lastPt))
                            {
                                measuredClocks = -(short)(lastPt - pt);
                            }
                            else
                            {
                                measuredClocks = (short)(pt - lastPt);
                            }
                            lastPt = pt;

                            /* Convert ASRC sample counter to bit clock units */
                            int asrcClocks = asrcCounter_play * 64;

                            /* Calulate error */
                            int error = asrcClocks - (int)measuredClocks;

                            /* Ignore any large error - most likely an SR change occurred */
                            if((error < 300) && (error > -300))
                            {
                                phaseError += error;
                                phaseErrorInt += phaseError;

                                float error_p = (float) (phaseError * 0.0000002);
                                float error_i = (float) (phaseErrorInt * 0.000000004);

                                float x = (error_p + error_i);

                                floatRatio_play = (idealFloatRatio_play + (x * idealFloatRatio_play));
                                floatRatio_rec = (idealFloatRatio_rec - (x * idealFloatRatio_rec));

                                /* Note, ASRC will Clamp ratio to 1000PPM error */
                                //if(floatRatio_play > (idealFloatRatio_play + 0.001))
                                //    floatRatio_play = idealFloatRatio_play + 0.001;
                                //if(floatRatio_play < (idealFloatRatio_play - 0.001))
                                //    floatRatio_play = idealFloatRatio_play - 0.001;

                                /* Convert FS ratio to fixed point */
                                fsRatio_rec = (uint64_t) (floatRatio_rec * (1LL<<60));
                            }

#if LOG_CONTROLLER
                            logCounterSub++;
                            if(logCounterSub == CONT_LOG_SUBSAMPLE)
                            {
                                logCounterSub = 0;
                                e[logCounter] = error;
                                f_p[logCounter] = fifo_play.fill;
                                f_r[logCounter] = fifo_rec.fill;
                                r_p[logCounter] = floatRatio_play;
                                r_r[logCounter] = floatRatio_rec;
                                sr[logCounter] = samFreq;

                                logCounter++;

                                if(logCounter >= CONT_LOG_SIZE)
                                {
                                    for(int i = 0; i < CONT_LOG_SIZE; i++)
                                    {
                                        printint(sr[i]);
                                        printchar(' ');
                                        printint(e[i]);
                                        printchar(' ');
                                        printint(f_p[i]);
                                        printchar(' ');
                                        printint(f_r[i]);
                                        printf(" %f", r_p[i]);
                                        printf(" %f\n", r_r[i]);
                                    }
                                    exit(1);
                                }
                            }
#endif
                            asrcCounter_play = 0;
                        }

#if (EXTRA_I2S_CHAN_COUNT_OUT > 0)
                        /* Send samples to SRC tasks. This function adds returned sample to FIFO */
                        asrcCounter_play += trigger_src(c_src_play, srcInputBuff_play, fifo_play, srcOutputBuff_play, fsRatio);
#endif
                    }
                }

                break;

            case i_i2s.init(i2s_config_t &?i2s_config, tdm_config_t &?tdm_config):
                i2s_config.mode = I2S_MODE_I2S;
                break;

            /* Inform the I2S slave whether it should restart or exit */
            case i_i2s.restart_check() -> i2s_restart_t restart:

                if(shutdownI2s)
                {
                    restart = I2S_SHUTDOWN;
                    shutdown = 1;
                }
                else
                {
                    restart = I2S_NO_RESTART;
                }
                break;

            case i_i2s.receive(size_t num_in, int32_t samples[num_in]):


#pragma loop unroll
                /* Add to recording path ASRC input buffer */
                for(size_t i = 0; i < EXTRA_I2S_CHAN_COUNT_IN; i++)
                {
                    srcInputBuff_rec[i/SRC_CHANNELS_PER_INSTANCE][sampleIdx_rec][i % SRC_CHANNELS_PER_INSTANCE] = samples[i];
                }

                sampleIdx_rec++;

                fsRatio = (uint64_t) (floatRatio_play * (1LL << 60));

                /* Trigger_src for record path */
                if(sampleIdx_rec == SRC_N_IN_SAMPLES)
                {
                    sampleIdx_rec = 0;

                    /* TODO we probably should synchronise use of fsRatio_rec */

                    /* Note, currenly don't use the count here since we expect the record and playback rates to match*/
                    asrcCounter_rec += trigger_src(c_src_rec, srcInputBuff_rec, fifo_rec, srcOutputBuff_rec, fsRatio_rec);
                }
                break;

            case i_i2s.send(size_t num_out, int32_t samples[num_out]):
            {
#if (EXTRA_I2S_CHAN_COUNT_OUT > 0)
                /* Provide samples from the SRC output FIFO */
                for(size_t i = 0; i < EXTRA_I2S_CHAN_COUNT_OUT; i++)
                {
                    int sample;
                    int error = fifo_pop(fifo_play, srcOutputBuff_play, sample);
                    samples[i] = sample;

                }
#endif
                break;
            }
        }
    }

    /* Return new sample frequency we need to switch to */
    return samFreq;
}

void src_task(streaming chanend c, int instance, int inputFsCode, int outputFsCode)
{
    int inputBuff[SRC_N_IN_SAMPLES * SRC_CHANNELS_PER_INSTANCE];
    int outputBuff[SRC_OUT_BUFF_SIZE];
    int sampsOut = 0;

    memset(inputBuff, 0, sizeof(inputBuff));
    memset(outputBuff, 0, sizeof(outputBuff));

#if USE_ASRC
    asrc_state_t sASRCState[SRC_CHANNELS_PER_INSTANCE];                                   // ASRC state machine state
    int iASRCStack[SRC_CHANNELS_PER_INSTANCE][ASRC_STACK_LENGTH_MULT * SRC_N_IN_SAMPLES * 100]; // Buffer between filter stages
    asrc_ctrl_t sASRCCtrl[SRC_CHANNELS_PER_INSTANCE];                                     // Control structure
    asrc_adfir_coefs_t asrc_adfir_coefs;                                                  // Adaptive filter coefficients
    uint64_t fsRatio;

    for(int ui = 0; ui < SRC_CHANNELS_PER_INSTANCE; ui++)
    {
        unsafe
        {
            // Set state, stack and coefs into ctrl structure
            sASRCCtrl[ui].psState                   = &sASRCState[ui];
            sASRCCtrl[ui].piStack                   = iASRCStack[ui];
            sASRCCtrl[ui].piADCoefs                 = asrc_adfir_coefs.iASRCADFIRCoefs;
        }
    }
    fsRatio = asrc_init(inputFsCode, outputFsCode, sASRCCtrl, SRC_CHANNELS_PER_INSTANCE, SRC_N_IN_SAMPLES, SRC_DITHER_SETTING);
#else
    ssrc_state_t sSSRCState[SRC_CHANNELS_PER_INSTANCE];                                     // State of SSRC module
    int iSSRCStack[SRC_CHANNELS_PER_INSTANCE][SSRC_STACK_LENGTH_MULT * SRC_N_IN_SAMPLES];   // Buffers between processing stages
    ssrc_ctrl_t sSSRCCtrl[SRC_CHANNELS_PER_INSTANCE];                                       // SSRC Control structure

    /* Set state, stack and coefs into ctrl structures */
    for(int ui = 0; ui < SRC_CHANNELS_PER_INSTANCE; ui++)
    {
        unsafe
        {
            sSSRCCtrl[ui].psState                   = &sSSRCState[ui];
            sSSRCCtrl[ui].piStack                   = iSSRCStack[ui];
        }
    }

    ssrc_init(inputFsCode, outputFsCode, sSSRCCtrl, SRC_CHANNELS_PER_INSTANCE, SRC_N_IN_SAMPLES, SRC_DITHER_SETTING);
#endif

    while(1)
    {
        uint64_t fsRatio_;

        /* Check for exit */
        if(stestct(c))
        {
            sinct(c);
            c :> inputFsCode;
            c :> outputFsCode;

            fsRatio = asrc_init(inputFsCode, outputFsCode, sASRCCtrl, SRC_CHANNELS_PER_INSTANCE, SRC_N_IN_SAMPLES, SRC_DITHER_SETTING);

            continue;
        }

        c :> fsRatio_;

#pragma loop unroll
        /* Receive samples to process */
        for(int i=0; i<SRC_N_IN_SAMPLES * SRC_CHANNELS_PER_INSTANCE; i++)
        {
            c :> inputBuff[i];
        }

        /* Send out the number of samples we have to output */
        c <: sampsOut;

        /* Send output samples */
#pragma loop unroll
        for(int i = 0; i < sampsOut * SRC_CHANNELS_PER_INSTANCE; i++)
        {
            c <: outputBuff[i];
        }

        /* Process input buffer into output buffer */
#if USE_ASRC
        sampsOut = asrc_process(inputBuff, outputBuff, fsRatio_, sASRCCtrl);
#else
        sampsOut = ssrc_process(inputBuff, outputBuff, sSSRCCtrl);
#endif
    }
}

fs_code_t sr_to_fscode(unsigned sr)
{
    switch (sr)
    {
        case 44100:
            return FS_CODE_44;
            break;
        case 48000:
            return FS_CODE_48;
            break;
        case 88200:
            return FS_CODE_88;
            break;
        case 96000:
            return FS_CODE_96;
            break;
        case 176400:
            return FS_CODE_176;
            break;
        case 192000:
            return FS_CODE_192;
            break;
        default:
            assert(0);
            break;
    }
}

void i2s_driver(chanend c)
{
    interface i2s_frame_callback_if i_i2s;
    streaming chan c_src_play[SRC_N_INSTANCES];
    streaming chan c_src_rec[SRC_N_INSTANCES];

    set_port_clock(p_off_bclk, clk_bclk);

    int usbSr = DEFAULT_FREQ;

    par
    {
        while(1)
        {
            par
            {
                {
                i2s_frame_slave(i_i2s, p_i2s_dout, 1, p_i2s_din, sizeof(p_i2s_din)/sizeof(p_i2s_din[0]), DATA_BITS, p_i2s_bclk, p_i2s_lrclk, clk_bclk);
                }
                {
                    set_core_high_priority_on();
                    usbSr = i2s_data(i_i2s, c, c_src_play, c_src_rec, usbSr);
                    set_core_high_priority_off();

                    for(int i=0; i < SRC_N_INSTANCES; i++)
                    unsafe
                    {
                        soutct(c_src_play[i], XS1_CT_END);
                        c_src_play[i] <: (int)sr_to_fscode(usbSr);
                        c_src_play[i] <: (int)FS_CODE_48;

                        soutct(c_src_rec[i], XS1_CT_END);
                        c_src_rec[i] <: (int)FS_CODE_48;
                        c_src_rec[i] <: (int)sr_to_fscode(usbSr);
                    }
                }
            }
        }

#if(EXTRA_I2S_CHAN_COUNT_OUT > 0)
        /* Playback SRC tasks */
        par (int i=0; i < SRC_N_INSTANCES; i++)
        {
            unsafe
            {
                src_task(c_src_play[i], i, sr_to_fscode(usbSr), FS_CODE_48);
            }
        }
#endif
        /* Record SRC tasks */
        par (int i = SRC_N_INSTANCES ; i < 2*SRC_N_INSTANCES; i++)
        {
            unsafe
            {
                src_task(c_src_rec[i-SRC_N_INSTANCES], i, FS_CODE_48, sr_to_fscode(usbSr));
            }
        }
    }
}
