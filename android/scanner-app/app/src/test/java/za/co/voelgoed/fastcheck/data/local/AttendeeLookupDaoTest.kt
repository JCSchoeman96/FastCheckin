package za.co.voelgoed.fastcheck.data.local

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

@RunWith(RobolectricTestRunner::class)
class AttendeeLookupDaoTest {
    private lateinit var database: FastCheckDatabase
    private lateinit var attendeeLookupDao: AttendeeLookupDao

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database =
            Room.inMemoryDatabaseBuilder(context, FastCheckDatabase::class.java)
                .allowMainThreadQueries()
                .build()
        attendeeLookupDao = database.attendeeLookupDao()

        runTest {
            database.scannerDao().upsertAttendees(
                listOf(
                    attendee(id = 1, ticketCode = "VG-100", firstName = "Jane", lastName = "Doe", email = "jane@example.com"),
                    attendee(id = 2, ticketCode = "VG-101", firstName = "Janet", lastName = "Smith", email = "janet@example.com"),
                    attendee(id = 3, eventId = 6, ticketCode = "VG-102", firstName = "Other", lastName = "Event", email = "other@example.com")
                )
            )
        }
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun observeAttendeeByIdIsEventScoped() = runTest {
        val attendee = attendeeLookupDao.observeAttendeeById(5, 1).first()
        val missing = attendeeLookupDao.observeAttendeeById(6, 1).first()

        assertThat(attendee?.ticketCode).isEqualTo("VG-100")
        assertThat(missing).isNull()
    }

    @Test
    fun searchCandidatesMatchTicketPrefixNameAndEmailWithinEvent() = runTest {
        val results =
            attendeeLookupDao.observeSearchCandidates(
                eventId = 5,
                exactTicketCode = "VG-100",
                prefixQuery = "VG-10%",
                containsQuery = "%jane%",
                limit = 50
            ).first()

        assertThat(results.map { it.id }).containsExactly(1L, 2L)
        assertThat(results.map { it.eventId }.distinct()).containsExactly(5L)
    }

    private fun attendee(
        id: Long,
        eventId: Long = 5,
        ticketCode: String,
        firstName: String?,
        lastName: String?,
        email: String?
    ): AttendeeEntity =
        AttendeeEntity(
            id = id,
            eventId = eventId,
            ticketCode = ticketCode,
            firstName = firstName,
            lastName = lastName,
            email = email,
            ticketType = "VIP",
            allowedCheckins = 2,
            checkinsRemaining = 1,
            paymentStatus = "completed",
            isCurrentlyInside = false,
            checkedInAt = null,
            checkedOutAt = null,
            updatedAt = "2026-03-28T10:00:00Z"
        )
}
