"""Tests for the pure genre mapping (docs/ARCHITEKTUR.md section 3.7)."""

from __future__ import annotations

import pytest

from faden_server.genres import (
    BIOGRAFIE,
    FANTASY_SF,
    GENRE_PRIORITY,
    GENRES,
    HUMOR,
    KINDER,
    KLASSIKER,
    KRIMI,
    ROMANE,
    SACHBUCH,
    genre_for_code,
    genre_for_subject,
    map_categories,
    pick_genre,
)


def test_exactly_the_eight_labels():
    assert GENRES == (
        "Krimi & Thriller",
        "Fantasy & Science-Fiction",
        "Romane",
        "Kinder & Jugend",
        "Sachbuch",
        "Biografie",
        "Klassiker",
        "Humor",
    )
    assert set(GENRE_PRIORITY) == set(GENRES)


@pytest.mark.parametrize(
    ("code", "genre"),
    [
        ("B", ROMANE),
        ("b", ROMANE),
        ("K", KINDER),
        ("830", ROMANE),
        ("833", ROMANE),
        ("833.914", ROMANE),
        ("823.92", ROMANE),
        ("837", HUMOR),
        ("817.54", HUMOR),
        ("920", BIOGRAFIE),
        ("929.2", BIOGRAFIE),
        ("940", SACHBUCH),
        ("500", SACHBUCH),
        ("004", SACHBUCH),
        (" 330 ", SACHBUCH),
        ("S", None),
        ("741.5", None),
        ("GN 1234", None),
        ("", None),
        ("unknown", None),
    ],
)
def test_genre_for_code(code, genre):
    assert genre_for_code(code) == genre


@pytest.mark.parametrize(
    ("subject", "genre"),
    [
        # Google Books / Open Library (English)
        ("Fiction / Mystery & Detective / General", KRIMI),
        ("Fiction / Thrillers / Suspense", KRIMI),
        ("Detective and mystery stories", KRIMI),
        ("Juvenile Fiction", KINDER),
        ("Juvenile Fiction / Mystery & Detective", KINDER),
        ("Young Adult Fiction / Fantasy", KINDER),
        ("Juvenile Nonfiction / Biography & Autobiography", KINDER),
        ("Biography & Autobiography", BIOGRAFIE),
        ("Biography & Autobiography / Personal Memoirs", BIOGRAFIE),
        ("Fiction / Science Fiction / General", FANTASY_SF),
        ("Science Fiction", FANTASY_SF),
        ("Fantasy", FANTASY_SF),
        ("Fantasy fiction", FANTASY_SF),
        ("Humor", HUMOR),
        ("Humor / General", HUMOR),
        ("Classics", KLASSIKER),
        ("Fiction / Classics", KLASSIKER),
        ("Fiction", ROMANE),
        ("Fiction / Literary", ROMANE),
        ("Fiction / Historical / General", ROMANE),
        ("History", SACHBUCH),
        ("Social Science", SACHBUCH),
        ("True Crime", SACHBUCH),
        ("Literary Criticism / German", SACHBUCH),
        ("Nonfiction", SACHBUCH),
        ("Non-fiction", SACHBUCH),
        # DNB: GND headings and VLB-Warengruppen (German)
        ("Kriminalroman", KRIMI),
        ("Regionalkrimi", KRIMI),
        ("(VLB-WN)1121: Hardcover, Softcover / Belletristik / Krimis, Thriller, Spionage", KRIMI),
        (
            "(VLB-WN)1116: Hardcover, Softcover / Belletristik / Science Fiction, Fantasy",
            FANTASY_SF,
        ),
        ("(VLB-WN)1111: Hardcover, Softcover / Belletristik / Hauptwerk vor 1945", KLASSIKER),
        ("(VLB-WN)1112: Hardcover, Softcover / Belletristik / Gegenwartsliteratur", ROMANE),
        ("(VLB-WN)2210: Kinder- und Jugendbücher / Bilderbücher", KINDER),
        ("(VLB-WN)1951: Sachbuch / Geschichte", SACHBUCH),
        ("(VLB-WN)1118: Belletristik / Biographien, Autobiographien", BIOGRAFIE),
        ("Kinderbuch", KINDER),
        ("Jugendbuch", KINDER),
        ("Biografie", BIOGRAFIE),
        ("Autobiografie", BIOGRAFIE),
        ("Satire", HUMOR),
        ("Humoristische Darstellung", HUMOR),
        ("Roman", ROMANE),
        ("Liebesroman", ROMANE),
        ("Erzählung", ROMANE),
        ("Geschichte 1933-1945", SACHBUCH),
        # Not a genre
        ("Hörbuch", None),
        ("Kurzgeschichte", None),
        ("Kriminalität", None),
        ("(Produktform)Audio disc", None),
        ("", None),
    ],
)
def test_genre_for_subject(subject, genre):
    assert genre_for_subject(subject) == genre


def test_pick_genre_prefers_the_more_specific_genre():
    assert pick_genre([ROMANE, KRIMI]) == KRIMI
    assert pick_genre([KRIMI, KINDER]) == KINDER
    assert pick_genre([SACHBUCH, BIOGRAFIE]) == BIOGRAFIE


def test_pick_genre_broad_buckets_tie_on_first_seen():
    assert pick_genre([SACHBUCH, ROMANE]) == SACHBUCH
    assert pick_genre([ROMANE, SACHBUCH]) == ROMANE


def test_pick_genre_skips_none_and_empty():
    assert pick_genre([None, None]) is None
    assert pick_genre([]) is None
    assert pick_genre([None, HUMOR]) == HUMOR


def test_map_categories_combines_codes_and_subjects():
    assert map_categories(["B", "830"], ["Kriminalroman"]) == KRIMI
    assert map_categories(["K", "833.92"]) == KINDER
    assert map_categories(["920"], ["Roman"]) == BIOGRAFIE
    # codes come first, so they decide between the broad buckets
    assert map_categories(["900"], ["Fiction"]) == SACHBUCH


def test_map_categories_unknown_is_none():
    assert map_categories([], []) is None
    assert map_categories(["S"], ["Hörbuch"]) is None
