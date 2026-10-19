# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
#
# `credentials` tapa todo lo que se carga como credencial de una integración: la
# acción de Avo las manda como `credentials__<clave>`, y la clave la decide el
# proveedor. OCA las llama `usr` y `psw`, que ninguna otra entrada cubre
# (TESIS-186). `psw` además va suelta por si viaja sin el prefijo.
Rails.application.config.filter_parameters += %i[
  passw email secret token _key crypt salt certificate otp ssn cvv cvc credentials psw
]
