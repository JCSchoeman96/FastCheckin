package za.co.voelgoed.fastcheck.feature.queue

import android.widget.EditText
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ManualQueueInputControllerTest {
    @Test
    fun enteredTextSurvivesUnrelatedStateEmission_andSubmissionUsesCurrentValue() {
        val editText = EditText(ApplicationProvider.getApplicationContext())
        val observedValues = mutableListOf<String>()
        val controller =
            ManualQueueInputController(
                input = editText,
                onTicketCodeChanged = observedValues::add
            )

        controller.bind()
        editText.setText("SMOKE-000001")
        controller.render("SMOKE-000001")

        var submittedValue: String? = null
        controller.submitCurrentValue { submittedValue = it }

        assertThat(editText.text.toString()).isEqualTo("SMOKE-000001")
        assertThat(observedValues.last()).isEqualTo("SMOKE-000001")
        assertThat(submittedValue).isEqualTo("SMOKE-000001")
    }

    @Test
    fun successfulQueueingClearsFieldOnlyWhenStateExplicitlyResetsIt() {
        val editText = EditText(ApplicationProvider.getApplicationContext())
        val controller =
            ManualQueueInputController(
                input = editText,
                onTicketCodeChanged = {}
            )

        controller.bind()
        editText.setText("SMOKE-000001")

        controller.render("SMOKE-000001")
        assertThat(editText.text.toString()).isEqualTo("SMOKE-000001")

        controller.render("")
        assertThat(editText.text.toString()).isEmpty()
    }
}
