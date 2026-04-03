package tmux

import (
	"os/exec"
	"strconv"
	"strings"
)

type Options struct{}

func NewOptions() *Options {
	return &Options{}
}

func (o *Options) Get(name string) (string, error) {
	out, err := exec.Command("tmux", "show-option", "-gqv", name).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func (o *Options) GetInt(name string) (int, error) {
	s, err := o.Get(name)
	if err != nil || s == "" {
		return 0, err
	}
	return strconv.Atoi(s)
}

func (o *Options) Set(name, value string) error {
	return exec.Command("tmux", "set-option", "-g", name, value).Run()
}

func (o *Options) Unset(name string) error {
	return exec.Command("tmux", "set-option", "-gu", name).Run()
}

func (o *Options) RefreshClients() error {
	return exec.Command("tmux", "refresh-client", "-S").Run()
}
