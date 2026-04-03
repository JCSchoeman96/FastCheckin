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
class CurrentAttendeeLookupRepositoryTest {
    private lateinit var database: FastCheckDatabase
    private lateinit var repository: CurrentAttendeeLookupRepository

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database =
            Room.inMemoryDatabaseBuilder(context, FastCheckDatabase::class.java)
                .allowMainThreadQueries()
                .build()
        repository = CurrentAttendeeLookupRepository(database.attendeeLookupDao())
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun blankQueryReturnsEmptyResults() = runTest {
        database.scannerDao().upsertAttendees(listOf(attendee(id = 1, ticketCode = "VG-001", firstName = "Jane")))

        val results = repository.search(5, "   ").first()

        assertThat(results).isEmpty()
    }

    @Test
    fun deterministicRankingPrefersExactTicketThenPrefixThenTextMatches() = runTest {
        database.scannerDao().upsertAttendees(
            listOf(
                attendee(id = 1, ticketCode = "VG-100", firstName = "Jane", lastName = "Doe"),
                attendee(id = 2, ticketCode = "VG-100-A", firstName = "Janet", lastName = "Roe"),
                attendee(id = 3, ticketCode = "ZZZ-999", firstName = "Jane", lastName = "Able")
            )
        )

        val results = repository.search(5, "VG-100").first()

        assertThat(results.map { it.id }).containsExactly(1L, 2L).inOrder()
    }

    @Test
    fun observeDetailExposesPersistedAttendanceTimestamps() = runTest {
        database.scannerDao().upsertAttendees(
            listOf(
                attendee(
                    id = 4,
                    ticketCode = "VG-200",
                    firstName = "Alex",
                    checkedInAt = "2026-03-28T09:00:00Z",
                    checkedOutAt = "2026-03-28T10:00:00Z"
                )
            )
        )

        val detail = repository.observeDetail(5, 4).first()

        assertThat(detail?.checkedInAt).isEqualTo("2026-03-28T09:00:00Z")
        assertThat(detail?.checkedOutAt).isEqualTo("2026-03-28T10:00:00Z")
    }

    private fun attendee(
        id: Long,
        ticketCode: String,
        firstName: String,
        lastName: String = "Person",
        checkedInAt: String? = null,
        checkedOutAt: String? = null
    ): AttendeeEntity =
        AttendeeEntity(
            id = id,
            eventId = 5,
            ticketCode = ticketCode,
            firstName = firstName,
            lastName = lastName,
            email = "$firstName@example.com",
            ticketType = "VIP",
            allowedCheckins = 2,
            checkinsRemaining = 1,
            paymentStatus = "completed",
            isCurrentlyInside = false,
            checkedInAt = checkedInAt,
            checkedOutAt = checkedOutAt,
            updatedAt = "2026-03-28T10:00:00Z"
        )
}
