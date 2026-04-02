package za.co.voelgoed.fastcheck.app.legacy

import android.content.Context
import android.util.AttributeSet
import android.view.LayoutInflater
import android.widget.FrameLayout
import androidx.camera.view.PreviewView
import za.co.voelgoed.fastcheck.databinding.ViewLegacyOperatorRuntimeBinding

class LegacyOperatorRuntimeView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : FrameLayout(context, attrs, defStyleAttr) {
    val binding: ViewLegacyOperatorRuntimeBinding =
        ViewLegacyOperatorRuntimeBinding.inflate(
            LayoutInflater.from(context),
            this,
            true
        )

    val previewView: PreviewView
        get() = binding.scannerPreview
}
