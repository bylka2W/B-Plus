#include "TSSShaders.h"

IMPLEMENT_GLOBAL_SHADER(FTSSShader_Copy, "/Plugin/TSS/Private/TSSCopy.usf", "CopyMain", SF_Compute);
IMPLEMENT_GLOBAL_SHADER(FTSSShader_EASU, "/Plugin/TSS/Private/TSSEASU.usf", "EASUMain", SF_Compute);
