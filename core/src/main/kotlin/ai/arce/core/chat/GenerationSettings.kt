package ai.arce.core.chat

/** The settings that shape one generation; read afresh for every request. */
data class GenerationSettings(
    val tone: String? = null,
    /** 0 = no limit. Asked of the model in the system prompt. */
    val maxChars: Int = 0,
    val maxTokens: Int = 2048,
    val searchEnabled: Boolean = true,
    /** Regenerations allowed for a cut-off tool call (詳細設定「エラー再書き込み回数」). */
    val retryLimit: Int = 2,
    /** Tool calls allowed before one reply must finish; stops tool loops. */
    val maxToolRounds: Int = 4,
    /** 0 = fastest, 1 = most accurate (spec §8.1 速度 / 精度). */
    val speedAccuracy: Float = 0.5f,
    /** Size of the loaded model in billions of parameters, when known. */
    val modelParamsB: Double? = null,
    /** Agent chosen by the user; null lets the selector decide. */
    val agentOverride: String? = null,
    /** Let the loaded model settle the agent when the keyword rules are unsure (spec §17.1). */
    val aiAgentSelection: Boolean = false,
) {
    /**
     * The fast end of the slider skips reasoning and shortens replies; the accurate end keeps
     * reasoning and allows longer replies. The user's own Thinking switch still wins when off.
     */
    fun effectiveThinking(userSwitch: Boolean): Boolean = userSwitch && speedAccuracy >= 0.25f

    fun effectiveMaxTokens(): Int = (maxTokens * (0.5f + speedAccuracy)).toInt().coerceAtLeast(256)
}
