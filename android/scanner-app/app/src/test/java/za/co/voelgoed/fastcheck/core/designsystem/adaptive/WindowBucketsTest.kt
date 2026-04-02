package za.co.voelgoed.fastcheck.core.designsystem.adaptive

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import androidx.compose.ui.unit.dp

class WindowBucketsTest {
    @Test
    fun widthBoundariesClassifyIntoExpectedBuckets() {
        assertThat(bucketForWidth(599.dp)).isEqualTo(WindowBucket.Compact)
        assertThat(bucketForWidth(600.dp)).isEqualTo(WindowBucket.Standard)
        assertThat(bucketForWidth(839.dp)).isEqualTo(WindowBucket.Standard)
        assertThat(bucketForWidth(840.dp)).isEqualTo(WindowBucket.Expanded)
    }

    @Test
    fun predicatesReflectTheBucketModel() {
        val compact = WindowBuckets(WindowBucket.Compact)
        val standard = WindowBuckets(WindowBucket.Standard)
        val expanded = WindowBuckets(WindowBucket.Expanded)

        assertThat(compact.isCompact).isTrue()
        assertThat(compact.isStandard).isFalse()
        assertThat(compact.isExpanded).isFalse()

        assertThat(standard.isCompact).isFalse()
        assertThat(standard.isStandard).isTrue()
        assertThat(standard.isExpanded).isFalse()

        assertThat(expanded.isCompact).isFalse()
        assertThat(expanded.isStandard).isFalse()
        assertThat(expanded.isExpanded).isTrue()
    }

    @Test
    fun fromWidthBuildsTheExpectedBucketHolder() {
        assertThat(WindowBuckets.fromWidth(320.dp)).isEqualTo(WindowBuckets(WindowBucket.Compact))
        assertThat(WindowBuckets.fromWidth(700.dp)).isEqualTo(WindowBuckets(WindowBucket.Standard))
        assertThat(WindowBuckets.fromWidth(900.dp)).isEqualTo(WindowBuckets(WindowBucket.Expanded))
    }
}
