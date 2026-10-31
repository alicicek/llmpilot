package store

import "testing"

// A move is recorded as unfinished — its account marked clone-suspect —
// before the account can be refreshed, and a rolled-back move puts the
// dir's record back exactly as it was.
func TestBeginRetirementMarksFirstAndUndoRestores(t *testing.T) {
	suspect := func(t *testing.T, s *Store, id string) bool {
		t.Helper()
		got, err := s.IsCloneSuspect(id)
		if err != nil {
			t.Fatal(err)
		}
		return got
	}

	t.Run("no record before", func(t *testing.T) {
		s := At(t.TempDir())
		undo, err := s.BeginRetirement(RetiredDir{ConfigDir: "/u/.claude-a", Email: "x@example.dev", AccountID: "x"})
		if err != nil {
			t.Fatal(err)
		}
		if !suspect(t, s, "x") {
			t.Fatal("an unfinished move did not mark its account")
		}
		if err := undo(); err != nil {
			t.Fatal(err)
		}
		r, _ := s.Retirements()
		if len(r.Dirs) != 0 || suspect(t, s, "x") {
			t.Fatalf("undo left a record or a mark: %+v", r)
		}
	})

	t.Run("a finished record before", func(t *testing.T) {
		s := At(t.TempDir())
		if err := s.RecordRetirement(RetiredDir{ConfigDir: "/u/.claude-a", AccountID: "x", Complete: true}); err != nil {
			t.Fatal(err)
		}
		undo, err := s.BeginRetirement(RetiredDir{ConfigDir: "/U/.claude-a/", AccountID: "x"})
		if err != nil {
			t.Fatal(err)
		}
		if !suspect(t, s, "x") {
			t.Fatal("a re-move of a finished dir did not mark its account")
		}
		if err := undo(); err != nil {
			t.Fatal(err)
		}
		r, _ := s.Retirements()
		if len(r.Dirs) != 1 || !r.Dirs[0].Complete || suspect(t, s, "x") {
			t.Fatalf("undo did not restore the finished record: %+v", r)
		}
	})

	t.Run("another unfinished dir keeps its mark", func(t *testing.T) {
		s := At(t.TempDir())
		if err := s.RecordRetirement(RetiredDir{ConfigDir: "/u/.claude-b", AccountID: "x"}); err != nil {
			t.Fatal(err)
		}
		undo, err := s.BeginRetirement(RetiredDir{ConfigDir: "/u/.claude-a", AccountID: "x"})
		if err != nil {
			t.Fatal(err)
		}
		if err := undo(); err != nil {
			t.Fatal(err)
		}
		if !suspect(t, s, "x") {
			t.Fatal("undoing one dir cleared a mark another unfinished dir still holds")
		}
	})
}
