vim9script noclear

if exists('*strchars')
    def clever_f#compat#strchars(str: string): number
        return strchars(str)
    enddef
else
    def clever_f#compat#strchars(str: string): number
        return substitute(str, '.', 'x', 'g')->strlen()
    enddef
endif

if exists('*xor')
    def clever_f#compat#xor(a: number, b: number): number
        return xor(a, b)
    enddef
else
    def clever_f#compat#xor(a: number, b: number): number
        return a && !b || !a && b
    enddef
endif

if exists('*reg_executing')
    def clever_f#compat#reg_executing(): string
        return reg_executing()
    enddef
else
    # reg_executing() was introduced at Vim 8.2.0020 and Neovim 0.4.0
    def clever_f#compat#reg_executing(): string
        return ''
    enddef
endif
