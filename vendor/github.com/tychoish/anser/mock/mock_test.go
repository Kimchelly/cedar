package mock

import (
	"testing"

	"github.com/mongodb/amboy/dependency"
	"github.com/stretchr/testify/assert"
	"github.com/tychoish/anser"
	"github.com/tychoish/anser/db"
	"github.com/tychoish/anser/model"
)

func TestInterfaces(t *testing.T) {
	assert := assert.New(t)

	assert.Implements((*db.Session)(nil), &Session{})
	assert.Implements((*db.Database)(nil), &Database{})
	assert.Implements((*db.Collection)(nil), &Collection{})
	assert.Implements((*db.Query)(nil), &Query{})
	assert.Implements((*db.Pipeline)(nil), &Pipeline{})
	assert.Implements((*db.Iterator)(nil), &Iterator{})

	assert.Implements((*model.DependencyNetworker)(nil), &DependencyNetwork{})
	assert.Implements((*anser.Environment)(nil), &Environment{})
	assert.Implements((*dependency.Manager)(nil), &DependencyManager{})
}
