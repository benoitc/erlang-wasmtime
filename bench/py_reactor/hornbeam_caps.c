/*
 * Copyright 2026 Benoit Chesneau
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * `_hornbeam`: how Python in the sandbox reaches a capability on the node.
 *
 * One function, `call(name, payload) -> str`, over two imports. `call` runs
 * the capability once and answers the length of its result, or a negative
 * number when the host refused; `take` copies that result into a buffer the
 * guest allocated for it. Two crossings rather than one with a guessed buffer,
 * so a capability never runs twice because its answer was bigger than hoped.
 *
 * Linked beside erlang_wasm's reactor shim. The module is registered from a
 * constructor, which a reactor's `_initialize` runs before `init()` starts the
 * interpreter, so the shim itself is used unchanged.
 */
#include <Python.h>

__attribute__((import_module("hornbeam"), import_name("call")))
int hornbeam_call(const char *name, int name_len, const char *in, int in_len);

__attribute__((import_module("hornbeam"), import_name("take")))
int hornbeam_take(char *out, int out_len);

static PyObject *call_fn(PyObject *self, PyObject *args)
{
    const char *name, *in;
    Py_ssize_t name_len, in_len;
    int n;
    PyObject *buf;

    (void)self;
    if (!PyArg_ParseTuple(args, "s#s#", &name, &name_len, &in, &in_len))
        return NULL;
    n = hornbeam_call(name, (int)name_len, in, (int)in_len);
    if (n < 0) {
        PyErr_Format(PyExc_PermissionError, "capability %s refused (%d)", name, n);
        return NULL;
    }
    buf = PyBytes_FromStringAndSize(NULL, n);
    if (buf == NULL)
        return NULL;
    if (hornbeam_take(PyBytes_AS_STRING(buf), n) != n) {
        Py_DECREF(buf);
        PyErr_SetString(PyExc_RuntimeError, "capability result lost");
        return NULL;
    }
    return buf;
}

static PyMethodDef methods[] = {
    {"call", call_fn, METH_VARARGS,
     "call(name, payload) -> bytes: run a capability the agent was granted."},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef module = {
    PyModuleDef_HEAD_INIT, "_hornbeam", NULL, -1, methods, NULL, NULL, NULL, NULL
};

static PyObject *init_module(void)
{
    return PyModule_Create(&module);
}

__attribute__((constructor))
static void register_module(void)
{
    PyImport_AppendInittab("_hornbeam", init_module);
}
