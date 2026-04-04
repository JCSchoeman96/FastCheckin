package za.co.voelgoed.fastcheck.data.repository

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import za.co.voelgoed.fastcheck.core.database.FastCheckDatabase
import za.co.voelgoed.fastcheck.data.local.AttendeeEntity

@RunWith(RobolectricTestRunner::class)
class CurrentEventAttendeeMetricsRepositoryTest {
    private lateinit var context: Context
    private lateinit var database: FastCheckDatabase
    private lateinit var repository: CurrentEventAttendeeMetricsRepository

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        database =
            Room.inMemoryDatabaseBuilder(context, FastCheckDatabase::class.java)
                .allowMainThreadQueries()
                .build()
        repository = CurrentEventAttendeeMetricsRepository(database.eventAttendeeMetricsDao())
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun observeMetricsFiltersByEventId() = runTest {
        database.scannerDao().upsertAttendees(
            listOf(
                attendee(id = 1, eventId = 5, isCurrentlyInside = true, checkinsRemaining = 0),
                attendee(id = 2, eventId = 5, isCurrentlyInside = false, checkinsRemaining = 2),
                attendee(id = 3, eventId = 7, isCurrentlyInside = true, checkinsRemaining = 3)
            )
        )

        val metrics = repository.observeMetrics(5).first()

        assertThat(metrics.cachedAttendeeCount).isEqualTo(2)
        assertThat(metrics.currentlyInsideCount).isEqualTo(1)
        assertThat(metrics.attendeesWithRemainingCheckinsCount).isEqualTo(1)
    }

    @Test
    fun observeMetricsReturnsZeroesForEmptyEventCache() = runTest {
        val metrics = repository.observeMetrics(5).first()

        assertThat(metrics.cachedAttendeeCount).isEqualTo(0)
        assertThat(metrics.currentlyInsideCount).isEqualTo(0)
        assertThat(metrics.attendeesWithRemainingCheckinsCount).isEqualTo(0)
    }

    @Test
    fun observeMetricsCountsRemainingCheckinsAndCurrentInsideSeparately() = runTest {
        database.scannerDao().upsertAttendees(
            listOf(
                attendee(id = 1, eventId = 5, isCurrentlyInside = true, checkinsRemaining = 1),
                attendee(id = 2, eventId = 5, isCurrentlyInside = true, checkinsRemaining = 0),
                attendee(id = 3, eventId = 5, isCurrentlyInside = false, checkinsRemaining = 2)
            )
        )

        val metrics = repository.observeMetrics(5).first()

        assertThat(metrics.cachedAttendeeCount).isEqualTo(3)
        assertThat(metrics.currentlyInsideCount).isEqualTo(2)
        assertThat(metrics.attendeesWithRemainingCheckinsCount).isEqualTo(2)
    }

    private fun attendee(
        id: Long,
        eventId: Long,
        isCurrentlyInside: Boolean,
        checkinsRemaining: Int
    ): AttendeeEntity =
        AttendeeEntity(
            id = id,
            eventId = eventId,
            ticketCode = "VG-$id",
            firstName = "Test",
            lastName = "User",
            email = "user$id@example.com",
            ticketType = "General",
            allowedCheckins = 2,
            checkinsRemaining = checkinsRemaining,
            paymentStatus = "completed",
            isCurrentlyInside = isCurrentlyInside,
            checkedInAt = null,
            checkedOutAt = null,
            updatedAt = "2026-03-13T08:50:00Z"
        )
}
