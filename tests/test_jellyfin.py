#!/usr/bin/env python3
"""Tests for the pure helpers in bin/omarchy-jellyfin.

The CLI has no .py extension (it is meant to be run, not imported), so it is
loaded by path here.
"""

import contextlib
import importlib.util
import io
import json
import os
import socket
import stat
import tempfile
import threading
import types
import unittest

SCRIPT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin", "omarchy-jellyfin"
)

spec = importlib.util.spec_from_loader(
    "omarchy_jellyfin", importlib.machinery.SourceFileLoader("omarchy_jellyfin", SCRIPT)
)
jf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jf)


class IsLocalHostTest(unittest.TestCase):
    def test_loopback_and_localhost(self):
        for host in ("localhost", "127.0.0.1", "localhost:8096", "::1"):
            self.assertTrue(jf.is_local_host(host), host)

    def test_private_ranges(self):
        for host in ("192.168.1.50:8096", "10.0.0.5", "172.16.0.9", "172.31.255.1"):
            self.assertTrue(jf.is_local_host(host), host)

    def test_public_addresses_are_not_local(self):
        for host in ("jellyfin.example.com", "8.8.8.8", "172.15.0.1", "172.32.0.1"):
            self.assertFalse(jf.is_local_host(host), host)

    def test_lan_names(self):
        for host in ("nas.local", "media.lan", "servern"):
            self.assertTrue(jf.is_local_host(host), host)

    def test_ipv6(self):
        # Bare IPv6 is all colons, so the old "everything before the first
        # colon" left "[" behind and called loopback a public address -- which
        # now decides whether plain HTTP is allowed at all.
        for host in ("::1", "[::1]", "[::1]:8096", "[fd00::1]:8096", "fe80::1"):
            self.assertTrue(jf.is_local_host(host), host)
        for host in ("[2001:4860:4860::8888]:8096", "2001:4860:4860::8888"):
            self.assertFalse(jf.is_local_host(host), host)


class HostOfTest(unittest.TestCase):
    def test_drops_a_port(self):
        self.assertEqual(jf.host_of("nas.local:8096"), "nas.local")
        self.assertEqual(jf.host_of("192.168.1.50:8096"), "192.168.1.50")

    def test_keeps_a_bare_host(self):
        self.assertEqual(jf.host_of("nas.local"), "nas.local")

    def test_unwraps_a_bracketed_ipv6(self):
        self.assertEqual(jf.host_of("[::1]:8096"), "::1")
        self.assertEqual(jf.host_of("[fd00::1]"), "fd00::1")

    def test_leaves_an_unbracketed_ipv6_whole(self):
        # Every colon there belongs to the address, none of them to a port.
        self.assertEqual(jf.host_of("fd00::1"), "fd00::1")

    def test_tolerates_junk(self):
        self.assertEqual(jf.host_of(None), "")
        self.assertEqual(jf.host_of("  NAS.Local  "), "nas.local")


class NormalizeServerTest(unittest.TestCase):
    def test_public_name_defaults_to_https(self):
        self.assertEqual(jf.normalize_server("jellyfin.example.com"), "https://jellyfin.example.com")

    def test_local_address_defaults_to_http(self):
        # A Jellyfin on the same machine serves plain HTTP on 8096, so guessing
        # https here would fail for every same-computer install.
        self.assertEqual(jf.normalize_server("localhost:8096"), "http://localhost:8096")
        self.assertEqual(jf.normalize_server("192.168.1.50:8096"), "http://192.168.1.50:8096")

    def test_keeps_explicit_scheme_and_port(self):
        self.assertEqual(jf.normalize_server("http://10.0.0.5:8096"), "http://10.0.0.5:8096")
        self.assertEqual(jf.normalize_server("https://localhost:8920"), "https://localhost:8920")

    def test_strips_trailing_slash_and_whitespace(self):
        self.assertEqual(jf.normalize_server("  https://jf.local/  "), "https://jf.local")

    def test_rejects_empty(self):
        with self.assertRaises(jf.JellyfinError):
            jf.normalize_server("   ")


class CandidateServersTest(unittest.TestCase):
    def test_explicit_scheme_is_taken_at_its_word(self):
        self.assertEqual(jf.candidate_servers("http://10.0.0.5:8096"), ["http://10.0.0.5:8096"])

    def test_local_tries_http_then_https(self):
        self.assertEqual(
            jf.candidate_servers("192.168.1.50:8096"),
            ["http://192.168.1.50:8096", "https://192.168.1.50:8096"],
        )

    def test_remote_never_falls_back_to_plain_http(self):
        # The downgrade this guards against: anyone able to make the https
        # attempt fail -- blocking 443 is enough -- would otherwise have the
        # login posted to them in clear text on the retry.
        self.assertEqual(
            jf.candidate_servers("jellyfin.example.com"),
            ["https://jellyfin.example.com"],
        )

    def test_plain_http_on_a_public_name_must_be_spelled_out(self):
        self.assertEqual(
            jf.candidate_servers("http://jellyfin.example.com"),
            ["http://jellyfin.example.com"],
        )

    def test_rejects_empty(self):
        with self.assertRaises(jf.JellyfinError):
            jf.candidate_servers("")


class ParseInterfaceAddressesTest(unittest.TestCase):
    IP_OUTPUT = (
        "1: eno1    inet 192.168.1.113/24 brd 192.168.1.255 scope global eno1\\       valid_lft forever\n"
        "2: wg0     inet 10.0.0.228/24 scope global wg0\\       valid_lft forever\n"
    )

    def test_extracts_every_address(self):
        self.assertEqual(
            jf.parse_interface_addresses(self.IP_OUTPUT),
            ["192.168.1.113/24", "10.0.0.228/24"],
        )

    def test_tolerates_empty_output(self):
        self.assertEqual(jf.parse_interface_addresses(""), [])
        self.assertEqual(jf.parse_interface_addresses(None), [])


class BroadcastTargetsTest(unittest.TestCase):
    def test_adds_a_directed_broadcast_per_interface(self):
        # The VPN case: without the directed broadcast the probe leaves by the
        # tunnel and a server on the real LAN never hears it.
        targets = jf.broadcast_targets(["192.168.1.113/24", "10.0.0.228/24"])
        self.assertIn(("192.168.1.255", "192.168.1.113"), targets)
        self.assertIn(("10.0.0.255", "10.0.0.228"), targets)

    def test_always_keeps_the_plain_broadcast_first(self):
        self.assertEqual(jf.broadcast_targets([])[0], ("255.255.255.255", None))

    def test_skips_point_to_point_and_junk(self):
        targets = jf.broadcast_targets(["10.8.0.2/32", "not-an-address", "192.168.1.5/31"])
        self.assertEqual(targets, [("255.255.255.255", None)])

    def test_deduplicates_identical_interfaces(self):
        targets = jf.broadcast_targets(["192.168.1.113/24", "192.168.1.113/24"])
        self.assertEqual(len(targets), 2)


class ParseDiscoveryTest(unittest.TestCase):
    def test_reads_address_and_name(self):
        found = jf.parse_discovery(
            ['{"Address":"http://192.168.1.50:8096","Name":"Vardagsrummet","Id":"x"}']
        )
        self.assertEqual(found, [{"address": "http://192.168.1.50:8096", "name": "Vardagsrummet"}])

    def test_deduplicates_repeated_replies(self):
        payload = '{"Address":"http://192.168.1.50:8096","Name":"A"}'
        self.assertEqual(len(jf.parse_discovery([payload, payload])), 1)

    def test_ignores_junk_and_addressless_replies(self):
        self.assertEqual(jf.parse_discovery(["not json", "{}", '{"Name":"x"}']), [])

    def test_falls_back_to_address_when_unnamed(self):
        found = jf.parse_discovery(['{"Address":"http://10.0.0.5:8096"}'])
        self.assertEqual(found[0]["name"], "http://10.0.0.5:8096")


class AuthHeaderTest(unittest.TestCase):
    def test_omits_token_before_login(self):
        header = jf.auth_header(None, "dev123")
        self.assertNotIn("Token=", header)
        self.assertIn('DeviceId="dev123"', header)

    def test_includes_token_after_login(self):
        self.assertIn('Token="abc"', jf.auth_header("abc", "dev123"))


class UserAgentTest(unittest.TestCase):
    """Cloudflare answers 403 to urllib's default User-Agent, so every request
    has to carry our own."""

    def capture(self, fn):
        seen = []

        def fake_urlopen(request, **_kwargs):
            seen.append(request)
            return contextlib.closing(io.BytesIO(b'{"ServerName": "x"}'))

        real = jf.urllib.request.urlopen
        jf.urllib.request.urlopen = fake_urlopen
        try:
            fn()
        finally:
            jf.urllib.request.urlopen = real
        self.assertEqual(len(seen), 1)
        return seen[0]

    def test_probe_sends_our_user_agent(self):
        request = self.capture(lambda: jf.probe_server("https://jf.example.com"))
        self.assertEqual(request.get_header("User-agent"), jf.USER_AGENT)

    def test_api_requests_send_our_user_agent(self):
        config = {"server": "https://jf.example.com", "deviceId": "dev", "token": None}
        request = self.capture(lambda: jf.api_get(config, "/System/Info"))
        self.assertEqual(request.get_header("User-agent"), jf.USER_AGENT)


class TrackFromItemTest(unittest.TestCase):
    def test_converts_ticks_to_seconds(self):
        track = jf.track_from_item({"Id": "1", "Name": "So What", "RunTimeTicks": 5_450_000_000})
        self.assertEqual(track["duration"], 545)

    def test_joins_multiple_artists(self):
        track = jf.track_from_item({"Id": "1", "Name": "x", "Artists": ["A", "B"]})
        self.assertEqual(track["artist"], "A, B")

    def test_falls_back_to_album_artist(self):
        track = jf.track_from_item({"Id": "1", "Name": "x", "AlbumArtist": "Miles Davis"})
        self.assertEqual(track["artist"], "Miles Davis")

    def test_tolerates_missing_fields(self):
        track = jf.track_from_item({})
        self.assertEqual(
            track,
            {"id": "", "title": "Unknown", "artist": "", "album": "", "artId": "", "duration": 0, "favorite": False},
        )

    def test_reads_favorite_from_user_data(self):
        track = jf.track_from_item({"Id": "1", "UserData": {"IsFavorite": True}})
        self.assertTrue(track["favorite"])

    def test_art_comes_from_the_album(self):
        track = jf.track_from_item({"Id": "track1", "Name": "x", "AlbumId": "album9"})
        self.assertEqual(track["artId"], "album9")

    def test_art_falls_back_to_the_track(self):
        track = jf.track_from_item({"Id": "track1", "Name": "x"})
        self.assertEqual(track["artId"], "track1")


class SearchEntryTest(unittest.TestCase):
    def test_artist(self):
        entry = jf.search_entry({"Type": "MusicArtist", "Id": "a1", "Name": "Miles Davis"})
        self.assertEqual(entry, {"type": "artist", "id": "a1", "name": "Miles Davis", "detail": ""})

    def test_album_is_credited_to_its_album_artist(self):
        entry = jf.search_entry(
            {"Type": "MusicAlbum", "Id": "b2", "Name": "Kind of Blue", "AlbumArtist": "Miles Davis"}
        )
        self.assertEqual(entry, {"type": "album", "id": "b2", "name": "Kind of Blue", "detail": "Miles Davis"})

    def test_album_falls_back_to_the_track_artists(self):
        # A compilation carries no album artist, only per-track credits.
        entry = jf.search_entry(
            {"Type": "MusicAlbum", "Id": "b2", "Name": "Now 42", "Artists": ["A", "B"]}
        )
        self.assertEqual(entry["detail"], "A, B")

    def test_track(self):
        entry = jf.search_entry(
            {"Type": "Audio", "Id": "c3", "Name": "So What", "Artists": ["Miles Davis"]}
        )
        self.assertEqual(entry, {"type": "track", "id": "c3", "name": "So What", "detail": "Miles Davis"})

    def test_untyped_items_are_treated_as_tracks(self):
        # /Items always sets Type, but a listing asked for Audio only cannot be
        # anything else, so a missing one must not lose the row.
        entry = jf.search_entry({"Id": "c3", "Name": "So What"})
        self.assertEqual(entry["type"], "track")

    def test_tolerates_missing_fields(self):
        for kind in ("MusicArtist", "MusicAlbum", "Audio"):
            entry = jf.search_entry({"Type": kind})
            self.assertEqual(entry["id"], "")
            self.assertEqual(entry["name"], "Unknown")
            self.assertEqual(entry["detail"], "")


class NamedEntryTest(unittest.TestCase):
    def test_id_and_name(self):
        self.assertEqual(
            jf.named_entry({"Id": "p1", "Name": "Late night"}),
            {"id": "p1", "name": "Late night", "detail": ""},
        )

    def test_tolerates_missing_fields(self):
        self.assertEqual(jf.named_entry({}), {"id": "", "name": "Unknown", "detail": ""})


class AlbumEntryTest(unittest.TestCase):
    ALBUM = {
        "Id": "b2",
        "Name": "Nothing",
        "AlbumArtist": "Meshuggah",
        "ProductionYear": 2002,
    }

    def test_credits_the_album_artist(self):
        self.assertEqual(
            jf.album_entry(self.ALBUM),
            {"id": "b2", "name": "Nothing", "detail": "Meshuggah"},
        )

    def test_falls_back_to_the_track_artists(self):
        entry = jf.album_entry({"Id": "b2", "Name": "Now 42", "Artists": ["A", "B"]})
        self.assertEqual(entry["detail"], "A, B")

    def test_under_an_artist_the_year_takes_the_column(self):
        # The credit is already known from the level above, so it would only
        # repeat the artist you clicked down the whole discography.
        self.assertEqual(jf.album_entry(self.ALBUM, implied_artist=True)["detail"], "2002")

    def test_an_undated_album_under_an_artist_says_nothing(self):
        entry = jf.album_entry({"Id": "b2", "Name": "Demo", "AlbumArtist": "X"}, True)
        self.assertEqual(entry["detail"], "")


class TrackEntriesTest(unittest.TestCase):
    def test_drops_an_artist_column_that_repeats(self):
        rows = jf.track_entries(
            [
                {"id": "1", "title": "Stengah", "artist": "Meshuggah"},
                {"id": "2", "title": "Rational Gaze", "artist": "Meshuggah"},
            ]
        )
        self.assertEqual([row["detail"] for row in rows], ["", ""])
        self.assertEqual([row["name"] for row in rows], ["Stengah", "Rational Gaze"])

    def test_keeps_it_when_the_listing_wanders(self):
        rows = jf.track_entries(
            [
                {"id": "1", "title": "So What", "artist": "Miles Davis"},
                {"id": "2", "title": "Stengah", "artist": "Meshuggah"},
            ]
        )
        self.assertEqual([row["detail"] for row in rows], ["Miles Davis", "Meshuggah"])

    def test_empty_listing(self):
        self.assertEqual(jf.track_entries([]), [])


class ArtistIdFieldTest(unittest.TestCase):
    def test_everything_they_appear_on_by_default(self):
        self.assertEqual(jf.artist_id_field(), "ArtistIds")
        self.assertEqual(jf.artist_id_field(False), "ArtistIds")

    def test_only_what_is_filed_under_them_when_asked(self):
        self.assertEqual(jf.artist_id_field(True), "AlbumArtistIds")


class BrowseParamsTest(unittest.TestCase):
    def test_a_plain_listing_is_alphabetical(self):
        params = jf.browse_params("MusicArtist", "u1", 2000)
        self.assertEqual(params["IncludeItemTypes"], "MusicArtist")
        self.assertEqual(params["SortBy"], "SortName")
        self.assertEqual(params["Limit"], 2000)
        self.assertEqual(params["userId"], "u1")
        self.assertNotIn("ArtistIds", params)

    def test_an_artists_albums_read_as_a_discography(self):
        params = jf.browse_params("MusicAlbum", "u1", 2000, artist_id="a9")
        self.assertEqual(params["ArtistIds"], "a9")
        self.assertEqual(params["SortBy"], "ProductionYear,SortName")

    def test_filters_on_the_same_field_playing_an_artist_does(self):
        # ArtistIds, not AlbumArtistIds: the discography has to be what
        # `play --artist` would actually queue, guest spots and all.
        self.assertIn("ArtistIds", jf.browse_params("MusicAlbum", "u1", 10, "a9"))

    def test_album_artists_only_stays_with_what_is_filed_under_them(self):
        params = jf.browse_params(
            "MusicAlbum", "u1", 2000, artist_id="a9", album_artists_only=True
        )
        self.assertEqual(params["AlbumArtistIds"], "a9")
        self.assertNotIn("ArtistIds", params)


class ArtistsListingTest(unittest.TestCase):
    def test_lists_everyone_from_the_artists_endpoint(self):
        endpoint, params = jf.artists_listing("u1", 2000)
        self.assertEqual(endpoint, "/Artists")
        self.assertEqual(params["userId"], "u1")
        self.assertEqual(params["Limit"], 2000)
        self.assertEqual(params["SortBy"], "SortName")
        self.assertNotIn("SearchTerm", params)

    def test_album_artists_only_uses_the_album_artists_endpoint(self):
        endpoint, _ = jf.artists_listing("u1", 2000, album_artists_only=True)
        self.assertEqual(endpoint, "/Artists/AlbumArtists")

    def test_search_term_rides_along(self):
        _, params = jf.artists_listing("u1", 5, "metallica")
        self.assertEqual(params["SearchTerm"], "metallica")


class ArtUrlTest(unittest.TestCase):
    CONFIG = {"server": "https://jf.local", "token": "tok"}

    def test_builds_an_authenticated_image_url(self):
        url = jf.art_url(self.CONFIG, {"artId": "album9"}, size=192)
        self.assertTrue(url.startswith("https://jf.local/Items/album9/Images/Primary?"))
        self.assertIn("api_key=tok", url)
        self.assertIn("fillHeight=192", url)

    def test_no_art_id_yields_no_url(self):
        self.assertEqual(jf.art_url(self.CONFIG, {"artId": ""}), "")
        self.assertEqual(jf.art_url(self.CONFIG, {}), "")
        self.assertEqual(jf.art_url(self.CONFIG, None), "")


class StreamUrlTest(unittest.TestCase):
    def test_builds_direct_play_url(self):
        config = {"server": "https://jf.local", "token": "tok"}
        self.assertEqual(
            jf.stream_url(config, "abc"),
            "https://jf.local/Audio/abc/stream?static=true&api_key=tok",
        )


class MediaTitleTest(unittest.TestCase):
    def test_leaves_artist_to_the_files_own_tags(self):
        # mpv-mpris reads artist/album from the streamed file, so folding the
        # artist into the title would show it twice in the bar.
        self.assertEqual(jf.media_title({"title": "So What", "artist": "Miles Davis"}), "So What")

    def test_falls_back_when_title_missing(self):
        self.assertEqual(jf.media_title({"title": "", "artist": "Miles Davis"}), "Unknown")


class FormatDurationTest(unittest.TestCase):
    def test_minutes_and_seconds(self):
        self.assertEqual(jf.format_duration(545), "9:05")

    def test_hours(self):
        self.assertEqual(jf.format_duration(3725), "1:02:05")

    def test_zero_and_negative(self):
        self.assertEqual(jf.format_duration(0), "0:00")
        self.assertEqual(jf.format_duration(-5), "0:00")
        self.assertEqual(jf.format_duration(None), "0:00")


class QueueIndexOfTest(unittest.TestCase):
    def setUp(self):
        self.tracks = [{"id": "a"}, {"id": "b"}, {"id": "c"}]

    def test_finds_the_track(self):
        self.assertEqual(jf.queue_index_of(self.tracks, "c"), 2)

    def test_unknown_id_starts_from_the_top(self):
        self.assertEqual(jf.queue_index_of(self.tracks, "zz"), 0)

    def test_empty_queue(self):
        self.assertEqual(jf.queue_index_of([], "a"), 0)


class VolumeTest(unittest.TestCase):
    def test_clamps_to_the_usable_range(self):
        self.assertEqual(jf.clamp_volume(-20), 0)
        self.assertEqual(jf.clamp_volume(500), 100)
        self.assertEqual(jf.clamp_volume(55), 55)

    def test_accepts_strings_and_floats(self):
        self.assertEqual(jf.clamp_volume("60"), 60)
        self.assertEqual(jf.clamp_volume(59.6), 60)

    def test_rejects_nonsense(self):
        for bad in ("loud", None, ""):
            with self.assertRaises(jf.JellyfinError):
                jf.clamp_volume(bad)

    def test_no_request_returns_the_current_level(self):
        self.assertEqual(jf.resolve_volume(45, None), 45)

    def test_steps_up_and_down(self):
        self.assertEqual(jf.resolve_volume(45, "up"), 50)
        self.assertEqual(jf.resolve_volume(45, "down"), 40)
        self.assertEqual(jf.resolve_volume(45, "up", step=20), 65)

    def test_stepping_stops_at_the_ends(self):
        self.assertEqual(jf.resolve_volume(2, "down"), 0)
        self.assertEqual(jf.resolve_volume(98, "up"), 100)

    def test_absolute_requests_win(self):
        self.assertEqual(jf.resolve_volume(45, "80"), 80)
        self.assertEqual(jf.resolve_volume(45, 12), 12)

    def test_too_loud_is_forgiven_but_negative_is_refused(self):
        # Asking for 500 is a person wanting it louder, so it lands on 100.
        # Asking for -1 is a caller that lost track of its own state -- the
        # widget's write timer did exactly that -- and clamping it to 0 would
        # mute the music while looking like an ordinary volume change.
        self.assertEqual(jf.resolve_volume(45, 500), 100)
        for below in (-1, "-1", -20):
            with self.assertRaises(jf.JellyfinError):
                jf.resolve_volume(45, below)

    def test_case_and_padding_are_forgiven(self):
        self.assertEqual(jf.resolve_volume(45, " UP "), 50)


class StatusVolumeTest(unittest.TestCase):
    QUEUE = [{"id": "1", "title": "x", "artist": "", "album": "", "duration": 10}]

    def test_reports_the_stored_level_when_mpv_is_not_running(self):
        # The panel's slider should show what the next track will start at
        # rather than snapping to zero.
        status = jf.merge_status(None, self.QUEUE, stored_volume=42)
        self.assertEqual(status["volume"], 42)

    def test_prefers_the_live_level(self):
        status = jf.merge_status({"pause": False, "playlist-pos": 0, "volume": 80}, self.QUEUE, 42)
        self.assertEqual(status["volume"], 80)

    def test_falls_back_when_mpv_has_no_level_yet(self):
        status = jf.merge_status({"pause": False, "playlist-pos": 0, "volume": None}, self.QUEUE, 42)
        self.assertEqual(status["volume"], 42)

    def test_a_live_zero_is_not_mistaken_for_missing(self):
        status = jf.merge_status({"pause": False, "playlist-pos": 0, "volume": 0}, self.QUEUE, 42)
        self.assertEqual(status["volume"], 0)


class EnqueueCommandsTest(unittest.TestCase):
    CONFIG = {"server": "http://jf.local", "token": "tok"}
    TRACKS = [
        {"id": "a", "title": "One", "artist": "X"},
        {"id": "b", "title": "Two", "artist": "X"},
        {"id": "c", "title": "Three", "artist": "X"},
    ]

    def loadfiles(self, commands):
        return [c for c in commands if c[0] == "loadfile"]

    def test_never_uses_append_play(self):
        # The regression: append-play raced the first track's HTTP open and
        # started the second track instead, so mpv played one thing while the
        # queue claimed another.
        commands = jf.enqueue_commands(self.CONFIG, self.TRACKS)
        modes = [c[2] for c in self.loadfiles(commands)]
        self.assertEqual(modes, ["append", "append", "append"])
        self.assertNotIn("append-play", modes)

    def test_clears_before_replacing(self):
        commands = jf.enqueue_commands(self.CONFIG, self.TRACKS)
        self.assertEqual(commands[0], ["playlist-clear"])
        self.assertEqual(commands[1], ["stop"])

    def test_keeps_the_existing_queue_when_not_replacing(self):
        commands = jf.enqueue_commands(self.CONFIG, self.TRACKS, replace=False)
        self.assertNotIn(["playlist-clear"], commands)

    def test_always_starts_playback_explicitly(self):
        commands = jf.enqueue_commands(self.CONFIG, self.TRACKS)
        self.assertEqual(commands[-2], ["playlist-play-index", 0])
        self.assertEqual(commands[-1], ["set_property", "pause", False])

    def test_starts_on_the_requested_track(self):
        commands = jf.enqueue_commands(self.CONFIG, self.TRACKS, start_id="c")
        self.assertEqual(commands[-2], ["playlist-play-index", 2])
        # The rest of the list is still queued around it.
        self.assertEqual(len(self.loadfiles(commands)), 3)

    def test_titles_ride_along_for_mpris(self):
        commands = jf.enqueue_commands(self.CONFIG, self.TRACKS)
        self.assertEqual(self.loadfiles(commands)[0][4]["force-media-title"], "One")

    def test_tls_verification_is_only_relaxed_when_asked(self):
        strict = jf.enqueue_commands(self.CONFIG, self.TRACKS)
        self.assertNotIn("tls-verify", self.loadfiles(strict)[0][4])

        relaxed_config = dict(self.CONFIG, insecure=True)
        relaxed = jf.enqueue_commands(relaxed_config, self.TRACKS)
        self.assertEqual(self.loadfiles(relaxed)[0][4]["tls-verify"], "no")


class BarePlayTest(unittest.TestCase):
    """The resume path of a bare `play`, driven with the I/O swapped out."""

    CONFIG = {"server": "http://jf.local", "token": "t", "userId": "u", "deviceId": "d"}
    QUEUE = [{"id": "a", "title": "One", "artist": "X"}]
    ARGS = types.SimpleNamespace(
        playlist=None, album=None, artist=None, search=None, item=None,
        favorites=False, shuffle=False, start=None, limit=200,
        album_artists_only=False,
    )

    def setUp(self):
        self.calls = []
        self.patch("load_config", lambda required=True: dict(self.CONFIG))
        self.patch("mpv_command", lambda *args: self.calls.append(("mpv_command", args)))
        self.patch(
            "enqueue",
            lambda config, tracks, replace=True, start_id=None: self.calls.append(
                ("enqueue", tracks)
            ),
        )

    def patch(self, name, stub):
        original = getattr(jf, name)
        setattr(jf, name, stub)
        self.addCleanup(setattr, jf, name, original)

    def test_resumes_by_unpausing_a_live_mpv(self):
        self.patch("read_queue", lambda: list(self.QUEUE))
        self.patch("mpv_running", lambda: True)
        jf.cmd_play(self.ARGS)
        self.assertEqual(self.calls, [("mpv_command", ("set_property", "pause", False))])

    def test_reloads_the_queue_when_mpv_died(self):
        # The crash case: queue.json survived, mpv did not. Unpausing a fresh
        # idle mpv would play nothing and print nothing, so the queue is
        # loaded again instead.
        self.patch("read_queue", lambda: list(self.QUEUE))
        self.patch("mpv_running", lambda: False)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            jf.cmd_play(self.ARGS)
        self.assertEqual(self.calls, [("enqueue", self.QUEUE)])
        self.assertIn("Reloaded 1 track.", out.getvalue())

    def test_nothing_queued_says_so(self):
        self.patch("read_queue", lambda: [])
        self.patch("mpv_running", lambda: False)
        with self.assertRaises(jf.JellyfinError):
            jf.cmd_play(self.ARGS)
        self.assertEqual(self.calls, [])

    def _artist_args(self, album_artists_only):
        return types.SimpleNamespace(
            playlist=None, album=None, artist="a9", search=None, item=None,
            favorites=False, shuffle=False, start=None, limit=200,
            album_artists_only=album_artists_only,
        )

    def test_playing_an_artist_includes_guest_spots_by_default(self):
        seen = {}
        self.patch("load_config", lambda required=True: dict(self.CONFIG))
        self.patch(
            "fetch_tracks",
            lambda config, params: (
                seen.setdefault("params", params),
                [{"id": "t1", "title": "One", "artist": "X"}],
            )[1],
        )
        self.patch("enqueue", lambda *a, **k: None)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            jf.cmd_play(self._artist_args(False))
        self.assertIn("ArtistIds", seen["params"])
        self.assertEqual(seen["params"]["ArtistIds"], "a9")

    def test_playing_an_artist_with_album_artists_only_stays_filed(self):
        seen = {}
        self.patch("load_config", lambda required=True: dict(self.CONFIG))
        self.patch(
            "fetch_tracks",
            lambda config, params: (
                seen.setdefault("params", params),
                [{"id": "t1", "title": "One", "artist": "X"}],
            )[1],
        )
        self.patch("enqueue", lambda *a, **k: None)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            jf.cmd_play(self._artist_args(True))
        self.assertIn("AlbumArtistIds", seen["params"])
        self.assertNotIn("ArtistIds", seen["params"])


class SearchLibraryRoutingTest(unittest.TestCase):
    """Artist search goes to /Artists, everything else to /Items."""

    CONFIG = {"server": "http://jf.local", "token": "t", "userId": "u", "deviceId": "d"}

    def run_search(self, album_artists_only):
        calls = []
        original = jf.api_get

        def fake(config, endpoint, params=None):
            calls.append(endpoint)
            if endpoint.startswith("/Artists"):
                return {"Items": [{"Type": "MusicArtist", "Id": "a1", "Name": "X"}]}
            return {"Items": []}

        jf.api_get = fake
        self.addCleanup(setattr, jf, "api_get", original)
        entries = jf.search_library(
            dict(self.CONFIG), "x", album_artists_only=album_artists_only
        )
        return calls, entries

    def test_artist_search_uses_the_artists_endpoint(self):
        calls, entries = self.run_search(False)
        self.assertIn("/Artists", calls)
        self.assertNotIn("/Artists/AlbumArtists", calls)
        self.assertEqual(entries[0]["type"], "artist")

    def test_album_artists_only_searches_album_artists(self):
        calls, _ = self.run_search(True)
        self.assertIn("/Artists/AlbumArtists", calls)


class FavoriteTest(unittest.TestCase):
    """Favorite/unfavorite by item id, with I/O swapped out."""

    CONFIG = {"server": "http://jf.local", "token": "t", "userId": "u", "deviceId": "d"}
    TRACK = {"id": "track1", "title": "One", "artist": "X", "favorite": False}

    def setUp(self):
        self.calls = []
        self.patch("load_config", lambda required=True: dict(self.CONFIG))
        self.patch("api_post", lambda *args: self.calls.append(("api_post", args)))
        self.patch("api_delete", lambda *args: self.calls.append(("api_delete", args)))
        self.patch(
            "write_queue",
            lambda tracks: self.calls.append(("write_queue", list(tracks))),
        )

    def patch(self, name, stub):
        original = getattr(jf, name)
        setattr(jf, name, stub)
        self.addCleanup(setattr, jf, name, original)

    def _args(self, item_id, action, json=False):
        return types.SimpleNamespace(item_id=item_id, action=action, json=json)

    def test_favorite_calls_post_and_updates_queue(self):
        self.patch("read_queue", lambda: [dict(self.TRACK)])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            jf.cmd_favorite(self._args("track1", "favorite"))
        self.assertEqual(self.calls, [
            ("api_post", (self.CONFIG, "/UserFavoriteItems/track1?userId=u", {})),
            ("write_queue", [{"id": "track1", "title": "One", "artist": "X", "favorite": True}]),
        ])
        self.assertIn("Favorited.", out.getvalue())

    def test_unfavorite_calls_delete_and_updates_queue(self):
        self.patch("read_queue", lambda: [dict(self.TRACK, favorite=True)])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            jf.cmd_favorite(self._args("track1", "unfavorite"))
        self.assertEqual(self.calls, [
            ("api_delete", (self.CONFIG, "/UserFavoriteItems/track1?userId=u")),
            ("write_queue", [{"id": "track1", "title": "One", "artist": "X", "favorite": False}]),
        ])
        self.assertIn("Unfavorited.", out.getvalue())

    def test_outputs_json_when_asked(self):
        self.patch("read_queue", lambda: [dict(self.TRACK)])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            jf.cmd_favorite(self._args("track1", "favorite", json=True))
        self.assertEqual(json.loads(out.getvalue()), {"favorite": True})

    def test_skips_queue_update_when_track_is_absent(self):
        self.patch("read_queue", lambda: [dict(self.TRACK)])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            jf.cmd_favorite(self._args("missing", "favorite"))
        self.assertEqual(self.calls, [
            ("api_post", (self.CONFIG, "/UserFavoriteItems/missing?userId=u", {})),
        ])

    def test_quotes_item_id_in_path(self):
        self.patch("read_queue", list)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            jf.cmd_favorite(self._args("a/b c", "favorite"))
        self.assertEqual(self.calls, [
            ("api_post", (self.CONFIG, "/UserFavoriteItems/a%2Fb%20c?userId=u", {})),
        ])


class MergeStatusTest(unittest.TestCase):
    def setUp(self):
        self.queue = [
            {"id": "1", "title": "So What", "artist": "Miles Davis", "album": "Kind of Blue", "duration": 545},
            {"id": "2", "title": "Blue in Green", "artist": "Miles Davis", "album": "Kind of Blue", "duration": 337},
        ]

    def test_not_running(self):
        status = jf.merge_status(None, self.queue)
        self.assertFalse(status["running"])
        self.assertFalse(status["playing"])
        self.assertIsNone(status["track"])

    def test_resolves_track_from_playlist_position(self):
        status = jf.merge_status(
            {"pause": False, "time-pos": 60, "duration": 545, "playlist-pos": 1}, self.queue
        )
        self.assertEqual(status["track"]["title"], "Blue in Green")
        self.assertTrue(status["playing"])
        self.assertEqual(status["elapsedText"], "1:00")

    def test_paused_is_not_playing(self):
        status = jf.merge_status({"pause": True, "playlist-pos": 0}, self.queue)
        self.assertTrue(status["paused"])
        self.assertFalse(status["playing"])

    def test_out_of_range_position_yields_no_track(self):
        status = jf.merge_status({"pause": False, "playlist-pos": 9}, self.queue)
        self.assertIsNone(status["track"])
        self.assertFalse(status["playing"])

    def test_idle_mpv_has_null_position(self):
        status = jf.merge_status({"pause": False, "playlist-pos": None}, self.queue)
        self.assertIsNone(status["track"])
        self.assertEqual(status["index"], -1)

    def test_progress_guards_against_zero_duration(self):
        status = jf.merge_status({"pause": False, "playlist-pos": 0, "duration": 0}, self.queue)
        self.assertEqual(status["progress"], 0.0)

    def test_falls_back_to_queue_duration_before_mpv_knows(self):
        status = jf.merge_status({"pause": False, "playlist-pos": 0, "duration": None}, self.queue)
        self.assertEqual(status["durationText"], "9:05")


class RuntimeDirTest(unittest.TestCase):
    def test_prefers_the_private_xdg_runtime_dir(self):
        self.assertEqual(
            jf.runtime_dir({"XDG_RUNTIME_DIR": "/run/user/1000"}, uid=1000),
            "/run/user/1000/omarchy-jellyfin",
        )

    def test_without_one_the_name_carries_the_uid(self):
        # /tmp is shared with every other user on the box, so two of them must
        # not end up pointed at the same directory -- whoever created it first
        # would own the mpv socket, and with it the Jellyfin token.
        path = jf.runtime_dir({}, uid=1000)
        self.assertTrue(path.endswith("omarchy-jellyfin-1000"), path)
        self.assertNotEqual(jf.runtime_dir({}, uid=1001), path)


class PrivateDirErrorTest(unittest.TestCase):
    def info(self, mode, uid=1000):
        return os.stat_result((mode, 0, 0, 1, uid, 0, 0, 0, 0, 0))

    def test_our_own_private_directory_is_fine(self):
        self.assertIsNone(
            jf.private_dir_error("/tmp/x", self.info(stat.S_IFDIR | 0o700), 1000)
        )

    def test_rejects_a_directory_owned_by_someone_else(self):
        # The attack os.makedirs(exist_ok=True) would otherwise walk into:
        # another user got there first and now owns the mpv socket.
        problem = jf.private_dir_error("/tmp/x", self.info(stat.S_IFDIR | 0o700, uid=1001), 1000)
        self.assertIn("another user", problem)

    def test_rejects_group_and_world_access(self):
        for mode in (0o770, 0o707, 0o777, 0o750, 0o701):
            self.assertIsNotNone(
                jf.private_dir_error("/tmp/x", self.info(stat.S_IFDIR | mode), 1000), oct(mode)
            )

    def test_rejects_a_symlink_or_a_plain_file(self):
        # lstat, so a symlink pointing at a directory we do own is still
        # refused: the target can be swapped after the check.
        self.assertIsNotNone(
            jf.private_dir_error("/tmp/x", self.info(stat.S_IFLNK | 0o700), 1000)
        )
        self.assertIsNotNone(
            jf.private_dir_error("/tmp/x", self.info(stat.S_IFREG | 0o600), 1000)
        )


class ItemsOfTest(unittest.TestCase):
    def test_reads_the_items_array(self):
        self.assertEqual(jf.items_of({"Items": [1, 2]}), [1, 2])

    def test_an_empty_body_is_an_empty_listing(self):
        # A reply with no body arrives as None, which used to be an
        # AttributeError traceback shown in the widget's panel.
        for empty in (None, {}, {"Items": None}):
            self.assertEqual(jf.items_of(empty), [])


class TruncationWarningTest(unittest.TestCase):
    def test_says_so_when_our_own_cap_was_hit(self):
        self.assertIn("500", jf.truncation_warning(500, 500, default_limit=500))

    def test_silent_below_the_cap(self):
        self.assertIsNone(jf.truncation_warning(499, 500, default_limit=500))

    def test_silent_for_a_limit_the_user_asked_for(self):
        # `play --shuffle --limit 50` did exactly what it said on the tin.
        self.assertIsNone(jf.truncation_warning(50, 50, default_limit=500))


class MpvExchangeTest(unittest.TestCase):
    """Drives _mpv_exchange against a stand-in for mpv's IPC socket."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "s")
        self.original = jf.SOCKET_PATH
        jf.SOCKET_PATH = self.path
        self.addCleanup(setattr, jf, "SOCKET_PATH", self.original)
        self.received = []

    def serve(self, expected, reply_for):
        """Answer `expected` requests, in reverse, after an unrelated event.

        Reverse order and the event in front of them are what mpv really does
        -- replies come back when each command finishes, with asynchronous
        property changes mixed in -- and both are what request_id has to
        survive.
        """
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(self.path)
        server.listen(1)
        self.addCleanup(server.close)

        def run():
            try:
                conn, _ = server.accept()
            except OSError:
                return
            with conn:
                conn.settimeout(3)
                buffer = b""
                while len(self.received) < expected:
                    chunk = conn.recv(65536)
                    if not chunk:
                        return
                    buffer += chunk
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        if line.strip():
                            self.received.append(json.loads(line.decode("utf-8")))
                out = b'{"event":"property-change","name":"volume","data":50}\n'
                for request in reversed(self.received):
                    out += json.dumps(reply_for(request)).encode("utf-8") + b"\n"
                conn.sendall(out)

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 3)

    def test_matches_replies_to_requests_by_id(self):
        self.serve(
            3,
            lambda request: {
                "error": "success",
                "data": request["command"][1].upper(),
                "request_id": request["request_id"],
            },
        )
        replies = jf._mpv_exchange(
            [{"command": ["get_property", name]} for name in ("one", "two", "three")]
        )
        self.assertEqual([r["data"] for r in replies], ["ONE", "TWO", "THREE"])

    def test_every_request_carries_its_own_id(self):
        self.serve(2, lambda r: {"error": "success", "data": 1, "request_id": r["request_id"]})
        jf._mpv_exchange([{"command": ["a"]}, {"command": ["b"]}])
        self.assertEqual([r["request_id"] for r in self.received], [0, 1])
        # And the commands still arrive in the order they were given, because
        # mpv runs them in that order: playlist-clear before the loadfiles.
        self.assertEqual([r["command"] for r in self.received], [["a"], ["b"]])

    def test_reads_properties_over_one_connection(self):
        self.serve(
            2,
            lambda request: {
                "error": "success",
                "data": 42 if request["command"][1] == "volume" else False,
                "request_id": request["request_id"],
            },
        )
        self.assertEqual(jf.mpv_get_many(("volume", "pause")), {"volume": 42, "pause": False})

    def test_a_failed_property_reads_as_missing_not_as_an_error(self):
        self.serve(
            2,
            lambda request: (
                {"error": "property unavailable", "request_id": request["request_id"]}
                if request["command"][1] == "time-pos"
                else {"error": "success", "data": 0, "request_id": request["request_id"]}
            ),
        )
        values = jf.mpv_get_many(("time-pos", "volume"))
        self.assertIsNone(values["time-pos"])
        self.assertEqual(values["volume"], 0)

    def test_nothing_listening_is_not_an_error(self):
        # No server bound at all: every caller reads this as "not playing".
        self.assertEqual(jf._mpv_exchange([{"command": ["a"]}, {"command": ["b"]}]), [None, None])
        self.assertIsNone(jf.mpv_get("volume"))
        self.assertFalse(jf.mpv_running())

    def test_an_empty_batch_never_opens_a_connection(self):
        self.assertEqual(jf._mpv_exchange([]), [])


class MissingConfigKeysTest(unittest.TestCase):
    COMPLETE = {"server": "https://jf.local", "token": "t", "userId": "u", "deviceId": "d"}

    def test_a_complete_config_is_missing_nothing(self):
        self.assertEqual(jf.missing_config_keys(self.COMPLETE), [])

    def test_names_what_is_missing(self):
        partial = dict(self.COMPLETE)
        del partial["userId"]
        self.assertEqual(jf.missing_config_keys(partial), ["userId"])

    def test_an_empty_value_counts_as_missing(self):
        self.assertEqual(jf.missing_config_keys(dict(self.COMPLETE, token="")), ["token"])

    def test_junk_is_missing_everything(self):
        for junk in (None, [], "nope", 7):
            self.assertEqual(len(jf.missing_config_keys(junk)), 4)


class LoadConfigTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.original = jf.CONFIG_PATH
        jf.CONFIG_PATH = os.path.join(self.dir.name, "config.json")
        self.addCleanup(setattr, jf, "CONFIG_PATH", self.original)

    def write(self, config):
        with open(jf.CONFIG_PATH, "w", encoding="utf-8") as handle:
            json.dump(config, handle)

    def test_missing_file_asks_you_to_log_in(self):
        with self.assertRaises(jf.JellyfinError):
            jf.load_config()
        self.assertIsNone(jf.load_config(required=False))

    def test_an_incomplete_config_names_the_gap(self):
        # A config written by a version that did not store userId: this used
        # to survive the check and fail as a KeyError mid-request.
        self.write({"server": "https://jf.local", "token": "t", "deviceId": "d"})
        with self.assertRaises(jf.JellyfinError) as caught:
            jf.load_config()
        self.assertIn("userId", str(caught.exception))

    def test_unreadable_json_is_reported_not_raised_raw(self):
        with open(jf.CONFIG_PATH, "w", encoding="utf-8") as handle:
            handle.write("{not json")
        with self.assertRaises(jf.JellyfinError):
            jf.load_config(required=False)

    def test_a_complete_config_loads(self):
        config = {"server": "https://jf.local", "token": "t", "userId": "u", "deviceId": "d"}
        self.write(config)
        self.assertEqual(jf.load_config(), config)


class SaveConfigTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.original_dir, self.original_path = jf.CONFIG_DIR, jf.CONFIG_PATH
        jf.CONFIG_DIR = self.dir.name
        jf.CONFIG_PATH = os.path.join(self.dir.name, "config.json")
        self.addCleanup(setattr, jf, "CONFIG_DIR", self.original_dir)
        self.addCleanup(setattr, jf, "CONFIG_PATH", self.original_path)

    def test_writes_the_token_unreadable_to_anyone_else(self):
        jf.save_config({"token": "secret"})
        mode = stat.S_IMODE(os.stat(jf.CONFIG_PATH).st_mode)
        self.assertEqual(mode, 0o600, oct(mode))

    def test_repairs_a_world_readable_config_from_an_older_version(self):
        # O_CREAT leaves an existing file's mode alone, so overwriting in place
        # kept a 0644 config at 0644 -- and the token with it.
        with open(jf.CONFIG_PATH, "w", encoding="utf-8") as handle:
            handle.write("{}")
        os.chmod(jf.CONFIG_PATH, 0o644)
        jf.save_config({"token": "secret"})
        self.assertEqual(stat.S_IMODE(os.stat(jf.CONFIG_PATH).st_mode), 0o600)

    def test_leaves_no_temporary_file_behind(self):
        jf.save_config({"token": "secret"})
        self.assertEqual(os.listdir(self.dir.name), ["config.json"])

    def test_round_trips(self):
        jf.save_config({"token": "secret", "server": "https://jf.local"})
        with open(jf.CONFIG_PATH, "r", encoding="utf-8") as handle:
            self.assertEqual(json.load(handle)["token"], "secret")


if __name__ == "__main__":
    unittest.main()
