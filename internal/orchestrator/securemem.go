package orchestrator

func zeroBytes(b []byte) {
	if b == nil {
		return
	}
	for i := range b {
		b[i] = 0
	}
}

func resetString(s *string) {
	if s == nil {
		return
	}
	*s = ""
}
