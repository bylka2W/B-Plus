#include "TSSViewExtension.h"
#include "PostProcess/PostProcessing.h"
#include "TSSRuntime.h"
#include "TSSShaders.h"
#include "Misc/Paths.h"

static TAutoConsoleVariable<float> CVarTSSDownscale(
	TEXT("r.TSS.DownscaleFactor"),
	1.0f,
	TEXT("TSS render resolution scale (0.1-1.0). 1.0 = full res, 0.5 = half res."),
	ECVF_RenderThreadSafe
);

static TAutoConsoleVariable<float> CVarTSSJitter(
	TEXT("r.TSS.JitterStrength"),
	1.0f,
	TEXT("TSS jitter amplitude (0.0=no jitter, 1.0=full pixel)."),
	ECVF_RenderThreadSafe
);

FTSSViewExtension::FTSSViewExtension(const FAutoRegister& AutoRegister)
	: FSceneViewExtensionBase(AutoRegister)
{
	Runtime = new FTSSRuntime();
}

FTSSViewExtension::~FTSSViewExtension()
{
	delete Runtime;
}

float FTSSViewExtension::Halton(int32 Index, int32 Base)
{
	float Result = 0.0f;
	float InvBase = 1.0f / Base;
	float Fraction = InvBase;
	while (Index > 0)
	{
		Result += (float)(Index % Base) * Fraction;
		Index /= Base;
		Fraction *= InvBase;
	}
	return Result;
}

void FTSSViewExtension::PreRenderView_RenderThread(FRDGBuilder& GraphBuilder, FSceneView& View)
{
	float Downscale = CVarTSSDownscale.GetValueOnRenderThread();
	if (Downscale < SMALL_NUMBER) return;
	float JitterStrength = CVarTSSJitter.GetValueOnRenderThread();
	if (JitterStrength < SMALL_NUMBER) return;
	FIntPoint ViewSize = View.UnscaledViewRect.Size();
	if (ViewSize.X < 1 || ViewSize.Y < 1) return;
	PreviousJitter = CurrentJitter;
	float DisplayJitter = 0.5f * JitterStrength;
	float RenderJitter = Downscale >= 1.0f ? DisplayJitter / Downscale : DisplayJitter * Downscale;
	float JitterX = (Halton(JitterFrameIndex, 2) - 0.5f) * RenderJitter;
	float JitterY = (Halton(JitterFrameIndex, 3) - 0.5f) * RenderJitter;
	CurrentJitter = FVector2f(JitterX, JitterY);
	{
		FMatrix& ProjMat = const_cast<FMatrix&>(View.ViewMatrices.GetProjectionMatrix());
		float InvWidth = 2.0f / ViewSize.X;
		float InvHeight = 2.0f / ViewSize.Y;
		ProjMat.M[2][0] += JitterX * InvWidth;
		ProjMat.M[2][1] += JitterY * InvHeight;
	}
	{
		FMatrix& ViewProjMat = const_cast<FMatrix&>(View.ViewMatrices.GetViewProjectionMatrix());
		ViewProjMat = View.ViewMatrices.GetViewMatrix() * View.ViewMatrices.GetProjectionMatrix();
	}
	{
		FMatrix& InvViewProjMat = const_cast<FMatrix&>(View.ViewMatrices.GetInvViewProjectionMatrix());
		InvViewProjMat = View.ViewMatrices.GetViewProjectionMatrix().Inverse();
	}
	JitterFrameIndex++;
}

void FTSSViewExtension::PrePostProcessPass_RenderThread(
	FRDGBuilder& GraphBuilder,
	const FSceneView& View,
	const FPostProcessingInputs& Inputs)
{
	Inputs.Validate();
	FRDGTextureRef SceneColor = (*Inputs.SceneTextures)->SceneColorTexture;
	FRDGTextureRef ViewFamilyOutput = Inputs.ViewFamilyTexture;
	if (!SceneColor || !ViewFamilyOutput || !Runtime) return;
	FRDGTextureRef Velocity = (*Inputs.SceneTextures)->GBufferVelocityTexture;
	FRDGTextureRef Depth = (*Inputs.SceneTextures)->SceneDepthTexture;
	FIntPoint DisplaySize = ViewFamilyOutput->Desc.Extent;
	float Downscale = CVarTSSDownscale.GetValueOnRenderThread();
	FVector4f PrevVP0(EForceInit::ForceInitToZero), PrevVP1(EForceInit::ForceInitToZero), PrevVP2(EForceInit::ForceInitToZero), PrevVP3(EForceInit::ForceInitToZero);
	FVector4f CurrInvVP0(EForceInit::ForceInitToZero), CurrInvVP1(EForceInit::ForceInitToZero), CurrInvVP2(EForceInit::ForceInitToZero), CurrInvVP3(EForceInit::ForceInitToZero);
	if (bUsePrevFrame)
	{
		FMatrix44f CurrInvVP = FMatrix44f(View.ViewMatrices.GetInvViewProjectionMatrix());
		CurrInvVP0 = FVector4f(CurrInvVP.M[0][0], CurrInvVP.M[0][1], CurrInvVP.M[0][2], CurrInvVP.M[0][3]);
		CurrInvVP1 = FVector4f(CurrInvVP.M[1][0], CurrInvVP.M[1][1], CurrInvVP.M[1][2], CurrInvVP.M[1][3]);
		CurrInvVP2 = FVector4f(CurrInvVP.M[2][0], CurrInvVP.M[2][1], CurrInvVP.M[2][2], CurrInvVP.M[2][3]);
		CurrInvVP3 = FVector4f(CurrInvVP.M[3][0], CurrInvVP.M[3][1], CurrInvVP.M[3][2], CurrInvVP.M[3][3]);
		FMatrix44f PrevVP = PrevFrameWorldToClip;
		PrevVP0 = FVector4f(PrevVP.M[0][0], PrevVP.M[0][1], PrevVP.M[0][2], PrevVP.M[0][3]);
		PrevVP1 = FVector4f(PrevVP.M[1][0], PrevVP.M[1][1], PrevVP.M[1][2], PrevVP.M[1][3]);
		PrevVP2 = FVector4f(PrevVP.M[2][0], PrevVP.M[2][1], PrevVP.M[2][2], PrevVP.M[2][3]);
		PrevVP3 = FVector4f(PrevVP.M[3][0], PrevVP.M[3][1], PrevVP.M[3][2], PrevVP.M[3][3]);
	}
	LastViewFamilyOutput = ViewFamilyOutput;
	Runtime->ExecutePlan(GraphBuilder, SceneColor, ViewFamilyOutput, Velocity, Depth, DisplaySize, Downscale, PrevVP0, PrevVP1, PrevVP2, PrevVP3, CurrInvVP0, CurrInvVP1, CurrInvVP2, CurrInvVP3, bUsePrevFrame);
	PrevFrameWorldToClip = FMatrix44f(View.ViewMatrices.GetViewProjectionMatrix());
	bUsePrevFrame = true;
}

float FTSSViewExtension::GetDownscaleFactor() const { return DownscaleFactor; }

void FTSSViewExtension::SetDownscaleFactor(float Factor) { DownscaleFactor = FMath::Clamp(Factor, 0.25f, 1.0f); }

void FTSSViewExtension::PostRenderView_RenderThread(
	FRDGBuilder& GraphBuilder,
	FSceneView& View)
{
	FRDGTextureRef TSSResult = Runtime->GetLastFinalOutput();
	if (!TSSResult || !LastViewFamilyOutput)
	{
		UE_LOG(LogTemp, Warning, TEXT("TSS: PostRenderView skipped (no FinalOutput or ViewFamily)"));
		return;
	}
	if (TSSResult->Desc.Extent == LastViewFamilyOutput->Desc.Extent && TSSResult->Desc.Format == LastViewFamilyOutput->Desc.Format)
	{
		AddCopyTexturePass(GraphBuilder, TSSResult, LastViewFamilyOutput);
	}
	else
	{
		FRDGTextureRef CopyDst = LastViewFamilyOutput;
		bool bHasUAV = EnumHasAnyFlags(LastViewFamilyOutput->Desc.Flags, TexCreate_UAV);
		if (!bHasUAV)
		{
			CopyDst = GraphBuilder.CreateTexture(
				FRDGTextureDesc::Create2D(LastViewFamilyOutput->Desc.Extent, LastViewFamilyOutput->Desc.Format,
					FClearValueBinding::None,
					TexCreate_UAV | TexCreate_ShaderResource),
				TEXT("TSS_PostRender_CopyDst"));
		}
		TShaderMapRef<FTSSShader_Copy> CopyShader(GetGlobalShaderMap(GMaxRHIFeatureLevel));
		FBPlusShaderParams* CParams = GraphBuilder.AllocParameters<FBPlusShaderParams>();
		CParams->Input0 = TSSResult;
		CParams->Output0 = GraphBuilder.CreateUAV(CopyDst);
		CParams->InputSampler = TStaticSamplerState<SF_Bilinear, AM_Clamp, AM_Clamp, AM_Clamp>::GetRHI();
		FIntVector GroupCount = FComputeShaderUtils::GetGroupCount(LastViewFamilyOutput->Desc.Extent, 8);
		GraphBuilder.AddPass(
			RDG_EVENT_NAME("TSS_PostRenderCopy"),
			CParams, ERDGPassFlags::Compute,
			[CopyShader, CParams, GroupCount](FRHIComputeCommandList& Cmd)
			{
				FComputeShaderUtils::Dispatch(Cmd, CopyShader, *CParams, GroupCount);
			});
		if (!bHasUAV)
		{
			AddCopyTexturePass(GraphBuilder, CopyDst, LastViewFamilyOutput);
		}
	}
}
