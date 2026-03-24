package za.co.voelgoed.fastcheck.feature.queue

import android.widget.EditText
import androidx.core.widget.doAfterTextChanged

class ManualQueueInputController(
    private val input: EditText,
    private val onTicketCodeChanged: (String) -> Unit
) {
    private var isApplyingState = false

    fun bind() {
        input.doAfterTextChanged { editable ->
            if (!isApplyingState) {
                onTicketCodeChanged(editable?.toString().orEmpty())
            }
        }
    }

    fun currentValue(): String = input.text?.toString().orEmpty()

    fun render(ticketCodeInput: String) {
        if (currentValue() == ticketCodeInput) {
            return
        }

        isApplyingState = true
        input.setText(ticketCodeInput)
        input.setSelection(input.text?.length ?: 0)
        isApplyingState = false
    }

    fun submitCurrentValue(onSubmit: (String) -> Unit) {
        onSubmit(currentValue())
    }
}
