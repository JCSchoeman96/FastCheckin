package za.co.voelgoed.fastcheck.app.scanning

import androidx.camera.view.PreviewView

class ScanPreviewSurfaceHolder {
    @Volatile
    private var previewView: PreviewView? = null

    fun attach(view: PreviewView) {
        previewView = view
    }

    fun detach(view: PreviewView) {
        if (previewView === view) {
            previewView = null
        }
    }

    fun hasPreviewSurface(): Boolean = previewView != null

    fun isPreviewVisible(): Boolean =
        previewView?.let { view ->
            view.isAttachedToWindow && view.visibility == android.view.View.VISIBLE && view.isShown
        } ?: false

    fun requirePreviewView(): PreviewView =
        checkNotNull(previewView) {
            "Scan preview is not attached. The scanner should only bind while the Scan surface is active."
        }
}
